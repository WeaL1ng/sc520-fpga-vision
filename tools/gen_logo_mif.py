#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_logo_mif.py — 把官方例程里的 anlogic_logo_rom.v（稀疏 case 组合逻辑）
转换成 TD ROM IP 可直接加载的 .mif + 调色板 Verilog + 接线说明。

背景
----
lab_ex3 的 anlogic_logo_rom.v 是 6,387 项 × 25bit 的 always@(*) case 表（纯组合），
它是 hdmi_mixer 那条关键路径的主体。

⚠ 关于"省多少 LUT"的重要更正（2026-09-18 第三轮核验，见
  doc/analysis/核验与纠偏-2026-09-18第三轮.md §2）：
  · 早期文档写的"实测约 2,495 个 LUT6"是**从位密度反推的估算，不是 TD 报出的实测值**。
  · TD 的 RTL 级报告里 Logo 是 38,479 个 **gate**（不是 LUT）；到 gate 级该模块已被吸收，
    布局布线后 u_hdmi_mixer 整模块只有 2,572 LUT（其中 u_anlogic_logo_rom 单列 54 LUT）。
  · 唯一可信的口径是 lab1↔lab3 差分：u_hdmi_mixer 46 → 2,572 LUT（+2,526），
    全设计 slices 12,358 → 14,852（+2,494）。**这 2,526 LUT 里有多少属于 Logo、多少属于
    手工字库与像素率常量除法，TD 的报告分不出来。**
  ⇒ 因此本脚本给出的"净收益"只能当**目标值**，必须用一次 P&R 实测确认；
    **改造的首要目的是拿回 HDMI_PIXEL_CLK 的时序裕量（改前仅 0.103 ns），不是省面积。**

本脚本把它转成 block ROM：
  1) 求 Logo 非空像素的包围盒并裁掉整行/整列的空白（官方素材上下都是空行）
  2) 量化成 bits 位调色板索引（0 = 透明）
  3) 输出 .mif + 调色板 Verilog + 几何参数头 + 接线说明

用法
----
  python gen_logo_mif.py <anlogic_logo_rom.v> [-o OUTDIR] [--bits 8] [--no-crop] [--pow2]

  --bits N   索引位宽（8 = 256 色, 推荐；10 = 1024 色可无损）
  --no-crop  不裁包围盒，保留完整 160x160 地址空间
  --pow2     深度向上取 2 的幂（个别 IP 向导版本要求）

不依赖任何第三方库。
"""

import argparse
import math
import os
import re
import sys
from collections import Counter

ENTRY_RE = re.compile(r"(\d+)\s*:\s*O_pixel\s*=\s*25'h([0-9a-fA-F]+)")


# ---------------------------------------------------------------- 解析

def parse_logo_rom(path):
    """返回 dict: addr -> (alpha, r, g, b)"""
    text = open(path, "r", encoding="utf-8", errors="replace").read()
    out = {}
    for m in ENTRY_RE.finditer(text):
        val = int(m.group(2), 16)
        out[int(m.group(1))] = ((val >> 24) & 1, (val >> 16) & 0xFF,
                                (val >> 8) & 0xFF, val & 0xFF)
    return out


# ------------------------------------------------------- 中位切分量化

class Box:
    __slots__ = ("colors", "counts")

    def __init__(self, colors, counts):
        self.colors, self.counts = colors, counts

    def total(self):
        return sum(self.counts)

    def widest(self):
        ch, rng = 0, -1
        for c in range(3):
            vals = [x[c] for x in self.colors]
            r = max(vals) - min(vals)
            if r > rng:
                ch, rng = c, r
        return ch

    def split(self):
        ch = self.widest()
        order = sorted(range(len(self.colors)), key=lambda i: self.colors[i][ch])
        colors = [self.colors[i] for i in order]
        counts = [self.counts[i] for i in order]
        total = sum(counts)
        acc, cut = 0, 1
        for i, c in enumerate(counts):
            acc += c
            if acc * 2 >= total:
                cut = min(max(i + 1, 1), len(colors) - 1)
                break
        return Box(colors[:cut], counts[:cut]), Box(colors[cut:], counts[cut:])


def median_cut(color_counts, n_boxes):
    colors = list(color_counts.keys())
    boxes = [Box(colors, [color_counts[c] for c in colors])]
    while len(boxes) < n_boxes:
        tgt, best = None, -1
        for i, b in enumerate(boxes):
            if len(b.colors) >= 2 and b.total() > best:
                best, tgt = b.total(), i
        if tgt is None:
            break
        b1, b2 = boxes[tgt].split()
        boxes[tgt:tgt + 1] = [b1, b2]
    pal = []
    for b in boxes:
        tw = sum(b.counts)
        if tw:
            pal.append(tuple(round(sum(c[k] * w for c, w in zip(b.colors, b.counts)) / tw)
                             for k in range(3)))
    return pal


def nearest(pal, rgb):
    r, g, b = rgb
    best, bd = 0, None
    for i, (pr, pg, pb) in enumerate(pal):
        d = (r - pr) ** 2 + (g - pg) ** 2 + (b - pb) ** 2
        if bd is None or d < bd:
            best, bd = i, d
    return best


# ---------------------------------------------------------------- 输出

def write_mif(path, values, bits):
    hexw = (bits + 3) // 4
    with open(path, "w", encoding="ascii") as f:
        f.write("DEPTH\t\t\t=\t%d;\n" % len(values))
        f.write("WIDTH\t\t\t=\t%d;\n" % bits)
        f.write("ADDRESS_RADIX\t=\tDEC;\n")
        f.write("DATA_RADIX\t\t=\tHEX;\n")
        f.write("CONTENT\t\t BEGIN\n\n")
        for a, v in enumerate(values):
            f.write("%d\t:\t%0*X;\n" % (a, hexw, v))
        f.write("\nEND;\n")


def write_palette_vh(path, palette):
    L = ["// 自动生成（gen_logo_mif.py），请勿手工修改",
         "// 索引 0 = 透明；1..N 对应下表颜色",
         "function [23:0] logo_palette;",
         "    input [11:0] I_idx;",
         "    begin",
         "        case (I_idx)",
         "            12'd0: logo_palette = 24'h000000;  // transparent"]
    for i, (r, g, b) in enumerate(palette, start=1):
        L.append("            12'd%d: logo_palette = 24'h%02x%02x%02x;" % (i, r, g, b))
    L += ["            default: logo_palette = 24'h000000;",
          "        endcase", "    end", "endfunction"]
    open(path, "w", encoding="utf-8").write("\n".join(L) + "\n")


def write_geom_vh(path, x0, y0, w, h, bits, depth, abits):
    L = ["// 自动生成（gen_logo_mif.py），请勿手工修改",
         "// Logo ROM 的几何参数：ROM 中只保存裁剪后的有效区域",
         "// 屏幕坐标 (LOGO_X+LOGO_ROM_X0+dx, LOGO_Y+LOGO_ROM_Y0+dy) 对应",
         "//   rom_addr = dy * LOGO_ROM_W + dx",
         "localparam LOGO_ROM_X0    = %d;" % x0,
         "localparam LOGO_ROM_Y0    = %d;" % y0,
         "localparam LOGO_ROM_W     = %d;" % w,
         "localparam LOGO_ROM_H     = %d;" % h,
         "localparam LOGO_ROM_DEPTH = %d;" % depth,
         "localparam LOGO_ROM_ABITS = %d;" % abits,
         "localparam LOGO_ROM_IDXBITS = %d;" % bits]
    open(path, "w", encoding="utf-8").write("\n".join(L) + "\n")


README = """# Logo ROM 改造说明（由 gen_logo_mif.py 自动生成）

## 0. 结论速览

> ⚠ **本节已按 2026-09-18 第三轮核验更正**（依据：`doc/analysis/核验与纠偏-2026-09-18第三轮.md` §2）。
> 早期版本写的"实测 ≈2,495 LUT6、净收益 −2,400 LUT6"**是从位密度反推的估算，不是 TD 的实测值**，
> 已作废。下表是各口径的**真实**报告值。

| 项 | 值 |
|---|---|
| 原始实现 | `anlogic_logo_rom.v` 稀疏 `case` 6,387 项 × 25 bit，**纯组合**（`always @(*)`） |
| 原始代价（TD **RTL 级**报告） | **38,479 个 gate**（注意是 gate，**不是 LUT**；该报告全设计 `#Total_luts` 仅 4,530） |
| 原始代价（TD **gate 级**） | 该模块**已从层级表中消失**（被吸收），无法单独计量 |
| 原始代价（**布局布线后**） | `u_hdmi_mixer` 整模块 **2,572 LUT**（其中 `u_anlogic_logo_rom` 单列 **54 LUT**） |
| **可信的差分口径** | lab1→lab3：`u_hdmi_mixer` **46 → 2,572 LUT（+2,526）**；全设计 slices **12,358 → 14,852（+2,494）**。<br>⚠ **这 2,526 LUT 中属于 Logo、属于手写点阵字库、属于像素率常量除法的各占多少，TD 的报告分不出来。** |
| 裁剪后有效区域 | x ∈ [{x0}, {x0w})，y ∈ [{y0}, {y0h})，共 {w}×{h} |
| ROM 尺寸 | 深度 **{depth}** × 宽度 **{bits}** bit = {bits_total} bit |
| **预计占用** | **{blocks} 个 ERAM 块**（器件共 108 块，lab3 已用 40 块） |
| 调色板 | {pal} 色，用 `logo_palette.vh` 里的 `case` 实现（≈{pal_lut} LUT） |
| 颜色量化 | {quant} |

**收益（修正后的表述）**

| 指标 | 改前（lab3 官方实测） | 目标 | 证据强度 |
|---|---|---|---|
| **`HDMI_PIXEL_CLK` 最差裕量** | **0.103 ns** | **≥ 1.5 ns** | ⭐ **确定**：组合链被 ERAM 同步读打断（综合阶段该域本是 WNS −1.296 ns） |
| DSP | 9/40 | **8/40** | **确定**：常量乘 160 从 `S_logo_y*LOGO_W` 移除 |
| ERAM | 40/108 | **{eram_after}/108** | 确定：容量算术 |
| slices | 14,852 (70.00%) | **待实测** | ⚠ **必须用一次 P&R 确认，不要预设数字** |

**⇒ 首要目的是时序，不是省面积。**（早期版本文档把"省 2,400 LUT"当主收益，是错的。）

## 1. 在 TD 里生成 ROM IP

`Tools → IP Core Generator → Memories & Storage Elements → ROM`
（IP 库中的 `ROM` / 器件族 `F9F0D0P0` 即 PH1P 系列）
底层为 `PH1P_LOGIC_ERAM`，本工程已在用（demosaic 的行缓冲、AWB 延迟缓冲）。

> ⚠ **ERAM 的硬性约束（不是风格建议）**：PH1P ERAM 用户手册明确要求
> **"ERAM 的地址与数据输入必须与输入时钟同步"**，否则工具**不会对这些路径做时序分析**，
> **ERAM 内容可能不可预测地翻转**。
> **⇒ 所以"Output Register = OUTREG（同步读）"是必须的**，`NOREG` 不可用。

| 参数 | 值 | 说明 |
|---|---|---|
| Memory Type | **Single Port ROM** | 对应 `` `define SP_ROM `` |
| Width | **{bits}** | 调色板索引位宽 |
| Depth | **{depth}** | 裁剪后的有效像素数 |
| Address Width | **{abits}** | 自动推导 = ceil(log2(depth)) |
| Output Register | **OUTREG（默认，不可改）** | **同步读，1 拍延迟**；见上面的 ERAM 硬性约束 |
| Implement | **20K** | 不要选 20K(FAST) |
| Load Init File | 勾选，选 **`logo_pixel.mif`** | 与本说明同目录 |
| Port A Clock | HDMI 像素时钟（75 MHz） | |

> ⚠ 若 IP 向导要求深度为 2 的幂，请用 `--pow2` 重新生成脚本输出。
> ⚠ `.mif` 的 `DEPTH` 必须与 IP 里填的 Depth 完全一致，否则加载失败。
> ⚠ ERAM 结构参考：**1 个 ERAM slice = 2 × ERAM20K + 1 个 FIFO 控制器**，**ERAM20K 固定 20 Kbit**。

## 2. 地址与流水线（替换 hdmi_mixer.v 里的 Logo 逻辑）

```
// ── 几何（来自 logo_geom.vh）
//   屏幕有效区域: x ∈ [LOGO_X+{x0}, LOGO_X+{x0w}), y ∈ [LOGO_Y+{y0}, LOGO_Y+{y0h})
//   rom_addr = dy * {w} + dx

// ① 行基址寄存器：每行只做一次乘法（原来每像素一次，还占了 1 个 DSP）
reg [14:0] row_base;                 // dy * LOGO_ROM_W
always @(posedge I_clk)
    if (I_line_start_gated)          // 在"进入有效区域行"的那一拍更新
        row_base <= dy_next * LOGO_ROM_W;   // 只在这时算乘法，常量 160 → 建议写成
                                            // (dy<<7)+(dy<<5)，彻底不用 DSP

// ② 逐像素：一次加法
wire in_logo = de_d2 && (x_d2 >= LOGO_X + LOGO_ROM_X0) && (x_d2 < LOGO_X + LOGO_ROM_X0 + LOGO_ROM_W)
                        && (y_d2 >= LOGO_Y + LOGO_ROM_Y0) && (y_d2 < LOGO_Y + LOGO_ROM_Y0 + LOGO_ROM_H);
wire [14:0] rom_addr = in_logo ? (row_base + (x_d2 - (LOGO_X + LOGO_ROM_X0))) : 15'd0;

// ③ 同步 ROM（IP，OUTREG → 1 拍延迟）
logo_pixel_rom u_logo_rom (.clka(I_clk), .addra(rom_addr), .doa(rom_idx));

// ④ 调色板 + 命中判决（第 2 拍）
always @(posedge I_clk) begin
    logo_hit_d <= in_logo && (rom_idx != 0);
    logo_col_d <= logo_palette(rom_idx);      // logo_palette.vh
end
```

**流水线对齐（务必核对）**
原来坐标用 `S_x_2d / S_y_2d`、数据用 `S_video_data_2d` 对齐 **2 拍**。
改造后 Logo 通路是 **2 级**（ROM OUTREG + 命中/调色板寄存器），
相对"组合式改写"其实只多 1 拍 —— 建议统一改为 **3 拍**（`_1d/_2d/_3d`），
把 `S_osd_hit / S_osd_color / 视频数据` 全部对齐到同一拍再进 `O_hdmi_data` 寄存器。
**验收方法**：自检模式下叠一个 1 像素棋盘或边框，确认 Logo 与背景无水平/垂直偏移。

## 3. 同时必须做的三件事（否则只解决一半）

1. **删掉像素率路径上的常量除法**
   `hdmi_mixer.v` 的 `S_pf_scale_x / 10'd24`、`/ 10'd15`、`/ 10'd8`：
   局部坐标只有 24 / 15 / 8 个取值 → 改成预计算查表（小 LUTRAM 或 `case`）。
2. **合并重复的 16 路 `case(S_pf_col)`**（原文件有 4 处几乎相同的 16 分支）
   → 抽成一个 `bit_select(S_pf_row_bits, S_pf_col)` 函数。
3. **别用 DSP 做乘 {w}**
   `S_logo_y * LOGO_W` 原来占掉 1 个 DSP（lab3 比 lab1 多 1 个 DSP）。
   改成行基址寄存器后，常量乘法用移位加法：{w} = {wshift}。

## 4. 预期收益（**必须用一次 P&R 验证，不要预设面积数字**）

> ⚠ 下表已按第三轮核验修正。**面积一栏不写目标值**——早期版本写的"slices ≤12,500"没有依据。

| 指标 | 改造前（lab3 官方实测） | 目标 / 判据 | 强度 |
|---|---|---|---|
| **HDMI_PIXEL_CLK 最差裕量** | **0.103 ns** | **≥ 1.5 ns** | ⭐ 主目标，结构上必然改善 |
| HDMI_SERIAL_CLK 最差裕量 | 0.336 ns | ≥ 0.8 ns | 应一并纳入门禁 |
| DDR usr_clk 最差裕量 | 0.576 ns | 观察即可（新工具版本下已回到 2.311 ns） | 随拥塞缓解回升 |
| DSP | 9/40 | **8/40** | 确定（常量乘 {w} 移除） |
| ERAM | 40/108 | **{eram_after}/108** | 确定（容量算术） |
| slices | 14,852 (70.00%) | **待实测** | ⚠ 不预设 |

**门禁命令（本工作区已有的回归工具）**

```powershell
powershell -ExecutionPolicy Bypass -File .\\tools\\run_regression.ps1 `
  -ProjectRoot <工程路径> -Stage P1 -Tag "logo->ERAM" -TdRoot F:\\al `
  -Targets @{{ HDMI_PIXEL_CLK = 1.5; HDMI_SERIAL_CLK = 0.8 }}
```

## 5. 生成产物清单

| 文件 | 用途 |
|---|---|
| `logo_pixel.mif` | ROM IP 的初始化文件 |
| `logo_palette.vh` | `function logo_palette`，索引 → 24bit RGB（`include` 到 hdmi_mixer.v） |
| `logo_geom.vh` | `LOGO_ROM_X0/Y0/W/H/DEPTH/ABITS/IDXBITS` localparam |
| `report.txt` | 颜色统计与量化误差（**含"面积收益待实测"的标注**） |
"""


def main():
    ap = argparse.ArgumentParser(description="anlogic_logo_rom.v -> ROM .mif + palette")
    ap.add_argument("src")
    ap.add_argument("-o", "--outdir", default=".")
    ap.add_argument("--bits", type=int, default=8, choices=(8, 9, 10, 11, 12))
    ap.add_argument("--no-crop", action="store_true", help="不裁剪包围盒")
    ap.add_argument("--pow2", action="store_true", help="深度向上取 2 的幂")
    ap.add_argument("--no-quantize", action="store_true")
    args = ap.parse_args()

    entries = parse_logo_rom(args.src)
    if not entries:
        print("!! 未解析到 case 项，请检查文件", file=sys.stderr)
        return 2

    opaque = {a: v for a, v in entries.items() if v[0]}
    if not opaque:
        print("!! 没有不透明像素", file=sys.stderr)
        return 2

    # ── 包围盒（线性地址按 160 宽推断；官方素材是 160x160）
    addrs = sorted(opaque)
    # 用最大地址推断宽度：官方 depth=25600 -> 160
    full_depth_guess = max(addrs) + 1
    W = 160
    while W * W < full_depth_guess and W < 4096:
        W *= 2
    if args.no_crop:
        x0, y0, w, h = 0, 0, W, W
    else:
        xs = [a % W for a in addrs]
        ys = [a // W for a in addrs]
        x0, x1 = min(xs), max(xs)
        y0, y1 = min(ys), max(ys)
        w, h = x1 - x0 + 1, y1 - y0 + 1

    depth_exact = w * h
    depth = 1 << math.ceil(math.log2(depth_exact)) if args.pow2 else depth_exact
    abits = max(1, math.ceil(math.log2(depth)))

    cc = Counter((v[1], v[2], v[3]) for v in opaque.values())
    uniq = len(cc)
    limit = (1 << args.bits) - 1

    print("case 项数           : %d" % len(entries))
    print("推断原图宽度        : %d" % W)
    print("包围盒              : x[%d,%d] y[%d,%d]  ->  %dx%d" % (x0, x1, y0, y1, w, h))
    print("ROM 深度            : %d (addr %d bit)" % (depth, abits))
    print("不透明像素          : %d" % len(opaque))
    print("唯一 RGB 颜色       : %d ; 调色板容量 %d" % (uniq, limit))

    quantized = uniq > limit
    if quantized and args.no_quantize:
        print("!! 颜色 %d > %d，拒绝量化" % (uniq, limit), file=sys.stderr)
        return 3
    if quantized:
        palette = median_cut(cc, limit)
        print("=> 量化 %d -> %d 色（中位切分）" % (uniq, len(palette)))
    else:
        palette = sorted(cc.keys())
        print("=> 颜色数未超容量，无损")

    lut = {c: i + 1 for i, c in enumerate(palette)}
    values = [0] * depth
    esum = emax = en = 0
    for a, (al, r, g, b) in opaque.items():
        x, y = a % W, a // W
        if not (x0 <= x < x0 + w and y0 <= y < y0 + h):
            continue
        rgb = (r, g, b)
        idx = lut[rgb] if rgb in lut else nearest(palette, rgb) + 1
        values[(y - y0) * w + (x - x0)] = idx
        pr, pg, pb = palette[idx - 1]
        e = max(abs(r - pr), abs(g - pg), abs(b - pb))
        esum += e
        emax = max(emax, e)
        en += 1

    os.makedirs(args.outdir, exist_ok=True)
    p_mif = os.path.join(args.outdir, "logo_pixel.mif")
    p_pal = os.path.join(args.outdir, "logo_palette.vh")
    p_geo = os.path.join(args.outdir, "logo_geom.vh")
    p_rd = os.path.join(args.outdir, "logo_rom_README.md")
    p_rep = os.path.join(args.outdir, "report.txt")

    write_mif(p_mif, values, args.bits)
    write_palette_vh(p_pal, palette)
    write_geom_vh(p_geo, x0, y0, w, h, args.bits, depth, abits)

    bits_total = depth * args.bits
    blocks = math.ceil(bits_total / 20480)
    pal_lut = math.ceil(len(palette) * 24 / 64)
    eram_after = 40 + blocks

    # 常量乘法的移位建议
    sh = []
    for k in range(15, -1, -1):
        if w >> k & 1:
            sh.append("(dy<<%d)" % k if k else "dy")
    wshift = " + ".join(sh) if sh else "0"

    rd = README.format(x0=x0, x0w=x0 + w, y0=y0, y0h=y0 + h, w=w, h=h,
                       depth=depth, bits=args.bits, abits=abits,
                       bits_total=bits_total, blocks=blocks,
                       pal=len(palette), pal_lut=pal_lut,
                       eram_add=blocks, eram_after=eram_after,
                       wshift=wshift,
                       quant=("无（无损）" if not quantized else
                              "579->%d 色，最大误差 %d/255、平均 %.2f/255（肉眼不可分辨）"
                              % (len(palette), emax, esum / max(en, 1))))
    open(p_rd, "w", encoding="utf-8").write(rd)

    with open(p_rep, "w", encoding="utf-8") as f:
        f.write("源文件              : %s\n" % args.src)
        f.write("case 项数           : %d\n" % len(entries))
        f.write("推断原图宽度        : %d\n" % W)
        f.write("包围盒 x0,y0,w,h    : %d,%d,%d,%d\n" % (x0, y0, w, h))
        f.write("ROM depth/abits     : %d / %d\n" % (depth, abits))
        f.write("索引位宽            : %d\n" % args.bits)
        f.write("唯一 RGB 颜色       : %d\n" % uniq)
        f.write("调色板色数          : %d\n" % len(palette))
        f.write("是否量化            : %s\n" % ("是" if quantized else "否"))
        if quantized:
            f.write("量化误差 最大/平均  : %d / %.2f  (每通道, 满量程 255)\n"
                    % (emax, esum / max(en, 1)))
        f.write("ROM 位总数          : %d bit\n" % bits_total)
        f.write("预计 ERAM 块(像素)  : %d\n" % blocks)
        f.write("调色板 LUT 估算     : %d\n" % pal_lut)
        f.write("\n")
        f.write("--- 面积收益：待实测，不要预设（2026-09-18 第三轮核验更正）---\n")
        f.write("早期版本此处写 '改造前 ≈2,495 个 LUT6 / 净收益 ≈-%d LUT6'，\n"
                % (2495 - pal_lut))
        f.write("该 2,495 是从位密度反推的估算，不是 TD 报告值，已作废。\n")
        f.write("各口径真实报告值：\n")
        f.write("  RTL 级   : anlogic_logo_rom = 38,479 个 gate（非 LUT）\n")
        f.write("  gate 级  : 该模块已从层级表消失（被吸收）\n")
        f.write("  布线后   : u_hdmi_mixer 整模块 2,572 LUT，其中 u_anlogic_logo_rom 单列 54 LUT\n")
        f.write("  可信差分 : u_hdmi_mixer 46 -> 2,572 LUT（lab1->lab3，+2,526）\n")
        f.write("             全设计 slices 12,358 -> 14,852（+2,494）\n")
        f.write("  但 2,526 LUT 中 Logo / 手写字库 / 像素率常量除法各占多少，TD 报告分不出来。\n")
        f.write("\n")
        f.write("主收益是时序：HDMI_PIXEL_CLK 改前仅 0.103 ns，目标 >= 1.5 ns。\n")
        f.write("确定的附带收益：DSP 9 -> 8（常量乘 %d 移除）、ERAM +%d -> %d/108。\n"
                % (w, blocks, 40 + blocks))
        f.write("依据：doc/analysis/核验与纠偏-2026-09-18第三轮.md §2、§10\n")

    print("\n输出:")
    for p in (p_mif, p_pal, p_geo, p_rd, p_rep):
        print("  %-28s %8d bytes" % (os.path.basename(p), os.path.getsize(p)))
    print("\n预计: %d 个 ERAM 块, 调色板 ≈%d LUT" % (blocks, pal_lut))
    print("收益: 主收益是时序（HDMI_PIXEL_CLK 0.103 -> >=1.5 ns）；")
    print("      确定的附带收益 DSP 9->8、ERAM 40->%d；面积收益待 P&R 实测。" % (40 + blocks))
    if quantized:
        print("量化误差: 最大 %d/255, 平均 %.2f/255" % (emax, esum / max(en, 1)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
