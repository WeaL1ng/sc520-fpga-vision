#!/usr/bin/env python3
# ============================================================
#  gen_logo_rom_v.py -- 生成 P1b 用的 Verilog Logo ROM（同步读常量 case 版）
#
#  输入（默认 tools/logo_rom/）：
#     logo_pixel.mif     13724 x 8bit  调色板索引（0 = 透明）
#     logo_palette.vh    索引 -> 24bit RGB
#     logo_geom.vh       几何参数（146x94 @ 偏移 7,34）
#
#  输出：
#     <out>/logo_rom_eram.v   module logo_rom_eram
#
#  设计要点（为什么这样做）：
#   1) 旧的 anlogic_logo_rom.v 是 always @(*) case(...) 的**组合**输出，
#      实测占最差路径约 6.1 ns / 12 级 LUT（HDMI_PIXEL_CLK 域）。
#   2) 这里改为**同步读**：地址打一拍 -> case 选择 -> 输出打一拍。
#      寄存的地址 + 寄存的输出让综合器把中间那层 case 放进 ERAM，
#      而不是展开成组合 LUT 网。
#   3) 用常量 case 而不是 reg 数组 + initial：
#      Verilog-2001（.v 默认）**不支持 initial 块**，TD 会报错；
#      而常量 case 无需初值、无需 IP 文件，纯文本可版本控制。
#   4) 用 (* ram_style = "block" *) 提示——工程里 edge_detect_96.v:44
#      已用同一写法成功推断出 ERAM，说明 TD 认这个属性。
#
#  端口延迟（重要）：O_idx 比 I_addr 晚 **2 拍**（addr_reg / idx_reg）。
#  调用方必须把 osd_hit / 坐标 / 视频数据对齐到同一拍。
#
#  用法：
#     python tools\gen_logo_rom_v.py
#     python tools\gen_logo_rom_v.py --out <目标 hdl_source 目录>
# ============================================================
import argparse
import os
import re
import sys

MODULE = 'logo_rom_eram'


def parse_palette(path):
    """从 logo_palette.vh 解析 索引 -> 24bit 颜色"""
    txt = open(path, 'r', encoding='utf-8', errors='replace').read()
    pal = {}
    for m in re.finditer(r"12'd(\d+)\s*:\s*logo_palette\s*=\s*24'h([0-9a-fA-F]{6})", txt):
        pal[int(m.group(1))] = int(m.group(2), 16)
    return pal


def parse_mif(path):
    """从 logo_pixel.mif 解析 地址 -> 索引"""
    depth = None
    width = None
    data = {}
    content = False
    for line in open(path, 'r', encoding='utf-8', errors='replace'):
        s = line.strip()
        if not s or s.startswith('--'):
            continue
        m = re.match(r'DEPTH\s*=\s*(\d+)', s, re.I)
        if m:
            depth = int(m.group(1))
            continue
        m = re.match(r'WIDTH\s*=\s*(\d+)', s, re.I)
        if m:
            width = int(m.group(1))
            continue
        if re.match(r'CONTENT\s+BEGIN', s, re.I):
            content = True
            continue
        if re.match(r'END\s*;', s, re.I):
            content = False
            continue
        if not content:
            continue
        m = re.match(r'(\d+)\s*:\s*([0-9a-fA-F]+)\s*;?$', s)
        if m:
            data[int(m.group(1))] = int(m.group(2), 16)
            continue
        m = re.match(r'\[\s*(\d+)\s*\.\.\s*(\d+)\s*\]\s*:\s*([0-9a-fA-F]+)\s*;?$', s)
        if m:
            a, b, v = int(m.group(1)), int(m.group(2)), int(m.group(3))
            for i in range(a, b + 1):
                data[i] = v
    return depth, width, data


def parse_geom(path):
    g = {}
    for line in open(path, 'r', encoding='utf-8', errors='replace'):
        m = re.match(r'\s*localparam\s+(\w+)\s*=\s*(\d+)\s*;', line)
        if m:
            g[m.group(1)] = int(m.group(2))
    return g


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument('--in', dest='indir', default=os.path.join(here, 'logo_rom'))
    ap.add_argument('--out', dest='outdir', default=os.path.join(here, 'logo_rom'))
    ap.add_argument('--name', default=MODULE)
    ap.add_argument('--no-palette', action='store_true',
                    help='只输出索引 ROM，不含调色板函数（由调用方自行提供）')
    args = ap.parse_args()

    mif = os.path.join(args.indir, 'logo_pixel.mif')
    pal_vh = os.path.join(args.indir, 'logo_palette.vh')
    geom_vh = os.path.join(args.indir, 'logo_geom.vh')
    for f in (mif, geom_vh):
        if not os.path.exists(f):
            sys.exit('缺少输入文件: %s' % f)
    if not args.no_palette and not os.path.exists(pal_vh):
        sys.exit('缺少输入文件: %s' % pal_vh)

    depth, width, data = parse_mif(mif)
    geom = parse_geom(geom_vh)
    pal = {} if args.no_palette else parse_palette(pal_vh)

    if depth is None:
        sys.exit('mif 里没找到 DEPTH')
    if width != 8:
        print('警告: mif WIDTH=%s，预期 8' % width)

    missing = sum(1 for a in range(depth) if a not in data)
    nonzero = sum(1 for a in range(depth) if data.get(a, 0) != 0)
    max_idx = max(data.values()) if data else 0
    idx_bits = max(1, max_idx.bit_length())
    abits = max(1, (depth - 1).bit_length())
    eram_blocks = -(-(depth * idx_bits) // 20480)

    print('mif        : DEPTH=%d WIDTH=%s  未列出=%d  非零项=%d  最大索引=%d'
          % (depth, width, missing, nonzero, max_idx))
    print('palette    : %d 色' % len(pal))
    print('geom       : %s' % {k: geom[k] for k in sorted(geom)})
    print('推导       : abits=%d  idx_bits=%d' % (abits, idx_bits))
    print('ERAM 估算  : %d x %d = %d bit  ≈ %d 块 (20Kb/块)'
          % (depth, idx_bits, depth * idx_bits, eram_blocks))

    out = os.path.join(args.outdir, args.name + '.v')
    L = []
    a = L.append
    a('// ============================================================')
    a('// %s.v  --  P1b: Logo 调色板索引 ROM（同步读，推断 ERAM）' % args.name)
    a('//')
    a('// 由 tools/gen_logo_rom_v.py 自动生成，请勿手工修改。')
    a('//   logo_pixel.mif  : %d x 8bit 索引（0 = 透明）' % depth)
    a('//   几何            : %dx%d @(%d,%d)  深度=%d'
      % (geom.get('LOGO_ROM_W', 0), geom.get('LOGO_ROM_H', 0),
         geom.get('LOGO_ROM_X0', 0), geom.get('LOGO_ROM_Y0', 0), depth))
    a('//   实际用到颜色数  : %d  最大索引=%d' % (len([v for v in set(data.values()) if v]), max_idx))
    a('//')
    a('// ⚠ 端口延迟：O_idx 比 I_addr 晚 2 拍（addr_reg -> case -> idx_reg）')
    a('//    调用方必须把 osd_hit / 坐标 / 视频数据对齐到同一拍。')
    a('//')
    a('// 与旧的 anlogic_logo_rom 的区别（这是 P1b 的核心）：')
    a('//    旧：always @(*) case(...) 组合输出 => 综合成巨型 LUT 网，')
    a('//        实测占 HDMI_PIXEL_CLK 域最差路径约 6.1 ns / 12 级 LUT。')
    a('//    新：地址与输出都打拍 => case 被放进 ERAM，组合链被切断。')
    a('//')
    a('// ERAM 硬性约束（PH1P 用户手册）：地址与数据输入必须与输入时钟同步，')
    a('// 否则工具不做时序分析、ERAM 内容可能不可预测地翻转 => 必须同步读。')
    a('// ============================================================')
    a('')
    a('module %s (' % args.name)
    a('    input  wire              I_clk,')
    a('    input  wire              I_rst_n,')
    a('    input  wire [%d:0]  I_addr,' % (abits - 1))
    a('    output reg  [%d:0]   O_idx' % (idx_bits - 1))
    a(');')
    a('')
    a('    // ---- 地址打一拍：ERAM 要求地址同步 ----')
    a('    reg [%d:0] addr_reg;' % (abits - 1))
    a('    always @(posedge I_clk or negedge I_rst_n) begin')
    a('        if(!I_rst_n) addr_reg <= {%d{1\'b0}};' % abits)
    a('        else         addr_reg <= I_addr;')
    a('    end')
    a('')
    a('    // ---- 同步读：寄存输出直接由常量 case 赋值 ----')
    a('    // 注意：属性必须作用在"被时序块赋值的寄存器"上，')
    a('    // 加在组合 always 块上无效（综合器不会推断 ERAM）。')
    a('    (* ram_style = "block" *)')
    a('    always @(posedge I_clk or negedge I_rst_n) begin')
    a('        if(!I_rst_n) begin')
    a('            O_idx <= {%d{1\'b0}};' % idx_bits)
    a('        end else begin')
    a('            case(addr_reg)')
    for ad in range(depth):
        a("                %d'd%d: O_idx <= %d'h%02x;" % (abits, ad, idx_bits, data.get(ad, 0)))
    a("                default: O_idx <= {%d{1'b0}};" % idx_bits)
    a('            endcase')
    a('        end')
    a('    end')
    a('')
    if pal:
        a('    // ---- 调色板：索引 -> 24bit RGB（纯组合，只有 %d 项，很便宜）----' % len(pal))
        a('    // 索引 0 = 透明（由调用方当作"无 Logo 像素"处理）')
        a('    function [23:0] logo_palette;')
        a('        input [%d:0] I_idx;' % (idx_bits - 1))
        a('        begin')
        a('            case (I_idx)')
        for k in sorted(pal.keys()):
            cmt = '  // transparent' if k == 0 else ''
            a("                %d'd%d: logo_palette = 24'h%06x;%s" % (idx_bits, k, pal[k], cmt))
        a("                default: logo_palette = 24'h000000;")
        a('            endcase')
        a('        end')
        a('    endfunction')
    a('')
    a('endmodule')
    a('')

    with open(out, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write('\n'.join(L))

    print('')
    print('已写出: %s  (%d 行)' % (out, len(L)))
    print('  case 项数 = %d（= ROM 深度）' % depth)


if __name__ == '__main__':
    main()
