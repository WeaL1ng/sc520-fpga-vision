#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
_port_sc520.py --- 把 lab4 从 SC500CS 换成 SC520CS（按厂商 SC520 例程与寄存器表）

依据
----
SC520CS摄像头资料/代码改动说明.txt：
  「已将 SC520CS 的 Lab1/2/3 工程统一更新为原厂 1280x720@60fps HD 模式配置」
SC520CS摄像头资料/lab_ex1_mipi_hdmi_SC520 (2)/.../user_source/  （例程）
  · uics520_cfg/uicfgcs520.v        配置状态机：读 0x3107/0x3108 校验芯片 ID，
                                    首写后等 5 ms，带 I2C 错误上报
  · uics520_cfg/uics520reg_720p60.v 720p60 初始化表
  · uics520_cfg/uics520regAE.v      AE 表：0x3812 组保持 + 曝光 0x3e00/01/02
                                    + 增益 0x3e09/0x3e06/0x3e07
  · uics520_cfg/SC520GainTbl.v      AG(16..176) -> 增益寄存器

与 SC500 的差异（已逐文件核对过两棵 RTL 树：93 个文件完全相同）
----
1. 寄存器/AE/增益表整套换掉（本脚本第 1、2 步）
2. MIPI 链路速率 480 -> 828 Mbps/Lane（sdc: 4.167ns -> 2.415ns），
   即 MIPI_RX_BYTE_CLK 从 60 MHz 提到 103.5 MHz（约束 9.66 ns）
3. MIPI PHY 接收均衡 0dB -> 3dB（厂商例程注释：828 Mbps/Lane 接收均衡）
4. 传感器上电时序：PWDNB 低 >=1 ms 后拉高，从拉高起 >=5 ms 才发第一次 I2C
   （SC500 原来直接 assign O_cam_rst = 1'b1）
5. AE 参数：AE 上限 1990 -> 1991（2*VTS-9），AG 上限 111 -> 176（32x）

不改的东西
----------
video_in / isp / DDR / HDMI 全部不动：SC520 的 720p60 输出与 SC500 同构
（两棵树的 video_in.v 只差我们自己的 P3 改动，csi_unpacket_2lane 只差一个调试输出）。

⚠ 编码：本工程 .v 是 GBK，.al/.prj/sdc 是 UTF-8。
   一律按原编码读改写回（edit 工具会把 GBK 当 UTF-8 写坏）。

用法
----
    python tools/_port_sc520.py            # dry-run，只报告
    python tools/_port_sc520.py --apply
"""
import re
import shutil
import sys
from pathlib import Path

W = Path(__file__).resolve().parent.parent
PROJ = W / "rtl_vendor/anlogic_example/lab_ex4_all_features_SC500_720P/lab_ex4_all_features"
HDL = PROJ / "user_source/hdl_source"
SRC = (W / "SC520CS摄像头资料/lab_ex1_mipi_hdmi_SC520 (2)/lab_ex1_mipi_hdmi_SC520"
           / "lab_ex1_mipi_hdmi/user_source/hdl_source")

COPY = ["uics520reg_720p60.v", "uics520regAE.v", "SC520GainTbl.v", "uicfgcs520.v"]


# ----------------------------------------------------------------- 编码工具
def read_text(p: Path):
    raw = p.read_bytes()
    bom = raw.startswith(b"\xef\xbb\xbf")
    body = raw[3:] if bom else raw
    for enc in ("utf-8", "gbk"):
        try:
            return body.decode(enc), enc, bom
        except UnicodeDecodeError:
            continue
    raise RuntimeError("无法解码 %s" % p)


def write_text(p: Path, text: str, enc: str, bom: bool):
    data = text.encode(enc)
    p.write_bytes((b"\xef\xbb\xbf" + data) if bom else data)


def newline_of(text: str) -> str:
    return "\r\n" if "\r\n" in text else "\n"


class Patcher:
    """对一份文本做若干替换，逐条统计命中次数。"""

    def __init__(self, path: Path, label: str):
        self.path = path
        self.label = label
        self.text, self.enc, self.bom = read_text(path)
        self.nl = newline_of(self.text)
        self.ops = []

    def sub(self, old: str, new: str, expect: int = 1):
        n = self.text.count(old)
        self.ops.append(("%-42s %d 处" % (old.strip().splitlines()[0][:42], n), n == expect))
        self.text = self.text.replace(old, new)

    def regex(self, pat: str, repl: str, expect: int = 1):
        new_text, n = re.subn(pat, repl, self.text)
        self.ops.append(("%-42s %d 处" % (pat[:42], n), n == expect))
        self.text = new_text

    def block(self, start_marker: str, end_after: str, new_block: str):
        i = self.text.find(start_marker)
        if i < 0:
            self.ops.append(("%-42s 未找到" % start_marker[:42], False))
            return
        j = self.text.find(end_after, i)
        k = self.text.find(");", j)
        k += 2
        # 吃掉行尾换行
        if self.text[k:k + 2] == "\r\n":
            k += 2
        elif self.text[k:k + 1] == "\n":
            k += 1
        self.text = self.text[:i] + new_block + self.text[k:]
        self.ops.append(("%-42s 替换整块" % start_marker.strip()[:42], True))

    def report(self, apply: bool):
        print("  %s" % self.label)
        ok = True
        for desc, good in self.ops:
            print("     %s %s" % ("[OK]" if good else "[!!]", desc))
            ok = ok and good
        if apply:
            write_text(self.path, self.text, self.enc, self.bom)
            print("     -> 已写回（%s%s）" % (self.enc, ", BOM" if self.bom else ""))
        return ok


# ----------------------------------------------------------------- 第 1 步：拷文件
def step_copy(apply: bool):
    dst_dir = HDL / "uics520_cfg"
    print("  目标目录 %s" % dst_dir.relative_to(W).as_posix())
    ok = True
    for f in COPY:
        src, dst = SRC / "uics520_cfg" / f, dst_dir / f
        if not src.exists():
            print("     [!!] 源文件缺失: %s" % src)
            ok = False
            continue
        same = dst.exists() and dst.read_bytes() == src.read_bytes()
        print("     %s %-24s %s" % ("[=]" if same else "[+]", f,
                                    "已存在且相同" if same else "待复制 %d B" % src.stat().st_size))
        if apply and not same:
            dst_dir.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dst)
    return ok


# ----------------------------------------------------------------- 第 2 步：顶层
def step_top(apply: bool):
    nl = "\n"
    p = Patcher(HDL / "design_top_wrapper.v", "design_top_wrapper.v")

    # (a) AE 参数
    p.sub(
        "    localparam [15:0] AE_AG_MAX = 16'd111;" + nl +
        "    localparam [15:0] AE_AE_MAX = 16'd1990;",
        "    // ★ 2026-10-21 换 SC520CS：增益表 SC520GainTbl 的有效输入是 16..176\n"
        "    //   （176 -> 0x3e09=0x1f = 32x 模拟增益上限），\n"
        "    //   曝光以半行为单位、VTS=1000 时合法上限 2*VTS-9 = 1991（厂商 ae_set.v 原注释）。\n"
        "    localparam [15:0] AE_AG_MAX = 16'd176;\n"
        "    localparam [15:0] AE_AE_MAX = 16'd1991;")

    # (b) ae_ctrl 的 AG_INIT：跟厂商默认 144（0x0f/0x00/0x80 = 16x）对齐
    p.sub("      .AG_INIT     ( 16'd80   ),", "      .AG_INIT     ( 16'd144  ),")

    # (c) 配置模块整块替换
    p.block(
        "    uicfgcs500_720p #(",
        "O_ae_cfg_done(S_ae_cfg_done)",
        "    uicfgcs520 #(\n"
        "      .CLK_DIV(23809524 / 100000 - 1)\n"
        "  ) u_uicfgcs520 (\n"
        "      .I_clk(S_24m_clk),               // 系统时钟输入\n"
        "      .I_rst_n(S_cam_i2c_ready),       // SC520CS: 上电时序完成后才允许 I2C\n"
        "      .I_ae_req(S_ae_req),\n"
        "      .I_ae(S_ae),\n"
        "      .I_ag(S_ag),\n"
        "      .O_cam_scl(O_cam_scl),           // I2C 总线 SCL\n"
        "      .IO_cam_sda(IO_cam_sda),         // I2C 总线 SDA\n"
        "      .O_cfg_done(S_cam_cfg_done),     // 寄存器初始化完成\n"
        "      .O_ae_cfg_done(S_ae_cfg_done),   // AE 配置完成\n"
        "      .O_sensor_id(S_cam_sensor_id),   // ★ SC520 新增：读回的芯片 ID\n"
        "      .O_sensor_id_ok(S_cam_sensor_id_ok),\n"
        "      .O_iic_error(S_cam_iic_error)\n"
        "  );\n")

    # (d) 传感器上电时序，替换 assign O_cam_rst = 1'b1;
    p.regex(
        r"[ \t]*assign[ \t]+O_cam_rst[ \t]*=[ \t]*1'b1;",
        "    // ------------------------------------------------------------------\n"
        "    //  ★ 2026-10-21 换 SC520CS：新增上电时序\n"
        "    //  厂商例程（design_top_wrapper.v:507）：PLL 锁定后先把传感器的\n"
        "    //  PWDNB/XSHUTDN 拉低 >=1 ms，再拉高；从拉高起再等 >=5 ms 才做\n"
        "    //  第一次 I2C。SC500 没有这个要求（原来这里直接 assign O_cam_rst = 1'b1）。\n"
        "    //  节奏参数按 23.81 MHz 的 pll_clk_24m 折算，与厂商例程同值。\n"
        "    // ------------------------------------------------------------------\n"
        "    localparam integer CAM_PWDNB_LOW_CYCLES = 23810;   // >= 1 ms @ 23.81 MHz\n"
        "    localparam integer CAM_I2C_START_CYCLES = 142857;  // 释放 + >= 5 ms\n"
        "    reg  [17:0] S_cam_power_cnt;\n"
        "    reg         S_cam_pwdnb;\n"
        "    reg         S_cam_i2c_ready;\n"
        "    wire [15:0] S_cam_sensor_id;\n"
        "    wire        S_cam_sensor_id_ok;\n"
        "    wire        S_cam_iic_error;\n"
        "\n"
        "    always @(posedge S_24m_clk or negedge S_pll_lock) begin\n"
        "        if (!S_pll_lock) begin\n"
        "            S_cam_power_cnt <= 18'd0;\n"
        "            S_cam_pwdnb     <= 1'b0;\n"
        "            S_cam_i2c_ready <= 1'b0;\n"
        "        end else begin\n"
        "            if (S_cam_power_cnt < CAM_I2C_START_CYCLES)\n"
        "                S_cam_power_cnt <= S_cam_power_cnt + 1'b1;\n"
        "            if (S_cam_power_cnt >= CAM_PWDNB_LOW_CYCLES)\n"
        "                S_cam_pwdnb <= 1'b1;\n"
        "            if (S_cam_power_cnt >= CAM_I2C_START_CYCLES - 1)\n"
        "                S_cam_i2c_ready <= 1'b1;\n"
        "        end\n"
        "    end\n"
        "\n"
        "    assign O_cam_rst = S_cam_pwdnb;")

    # (e) MIPI PHY 接收均衡：828 Mbps/Lane 需要 3dB
    p.sub('( "0dB"   ),//"0dB","1.5dB","3dB"', '( "3dB"   ),//"0dB","1.5dB","3dB"')

    return p.report(apply)


# ----------------------------------------------------------------- 第 3 步：ae_set
def step_ae_set(apply: bool):
    p = Patcher(HDL / "uiisp_beta/ae_set.v", "uiisp_beta/ae_set.v")

    p.sub("r_ae_set = 1990, r_ag_set = 80;", "r_ae_set = 1991, r_ag_set = 144;")
    p.sub("r_ae_set <= 1990;", "r_ae_set <= 1991;")
    p.sub("r_ag_set <= 80;", "r_ag_set <= 144;")
    p.sub("(r_ae_set < 1990)", "(r_ae_set < 1991)")
    # r_ag 初值故意取 17（≠ 目标 144）：这样配置完成后必然产生一次 AE/AG 组写，
    # 把目标增益真正送进传感器（厂商例程同款技巧）。
    p.sub("r_ae     <= 1990;", "r_ae     <= 1991;")
    p.sub("r_ag     <= 80;", "r_ag     <= 17;")
    # 注释同步
    p.sub("// HD 60 fps mode uses VTS=1000.  Exposure 1990 is about 995 lines",
          "// SC520CS HD 60 fps mode uses VTS=1000.  Exposure 1991 is the legal max")
    p.sub("// SC500GainTbl to 0x0f20, approximately 4x analogue gain.",
          "// SC520GainTbl: 144 -> 0x3e09=0x0f / 0x3e06=0x00 / 0x3e07=0x80 = 16x analogue.")
    return p.report(apply)


# ----------------------------------------------------------------- 第 4 步：sdc
def step_sdc(apply: bool):
    p = Patcher(PROJ / "td_project/camera_to_dsi_display.sdc", "camera_to_dsi_display.sdc")
    p.sub(
        "create_clock -name {mipi_rx_ck_pad} -period 4.167 -waveform {0.000 2.083}",
        "create_clock -name {mipi_rx_ck_pad} -period 2.415 -waveform {0.000 1.208}")
    return p.report(apply)


# ----------------------------------------------------------------- 第 5 步：登记
def step_register(apply: bool):
    files = ["uics520_cfg/uics520reg_720p60.v",
             "uics520_cfg/uics520regAE.v",
             "uics520_cfg/SC520GainTbl.v",
             "uics520_cfg/uicfgcs520.v"]
    targets = [
        (PROJ / "td_project/camera_to_dsi_display.al", "../.."),
        (PROJ / "td_project/camera_to_dsi_display_Runs/syn_1/camera_to_dsi_display.prj", "../../.."),
        (PROJ / "td_project/camera_to_dsi_display_Runs/phy_1/camera_to_dsi_display.prj", "../../.."),
    ]
    ok = True
    for path, prefix in targets:
        text, enc, bom = read_text(path)
        nl = newline_of(text)
        have = [f for f in files if f in text]
        need = [f for f in files if f not in text]
        orders = [int(m) for m in re.findall(r'CompileOrder" Val="(\d+)"', text)]
        nxt = (max(orders) + 1) if orders else 1
        print("  %s" % path.name)
        print("     已有 %d/%d，待加 %s，CompileOrder 从 %d 起（现有最大 %d）" % (
            len(have), len(files), need or "无", nxt, max(orders) if orders else 0))
        if not need:
            continue
        block = ""
        for i, f in enumerate(need):
            block += (
                '            <File Path="%s/user_source/hdl_source/%s">%s'
                '                <FileInfo>%s'
                '                    <Attr Name="UsedInSyn" Val="true"/>%s'
                '                    <Attr Name="UsedInP&R" Val="true"/>%s'
                '                    <Attr Name="BelongTo" Val="design_1"/>%s'
                '                    <Attr Name="CompileOrder" Val="%d"/>%s'
                '                </FileInfo>%s'
                '            </File>%s'
            ) % (prefix, f, nl, nl, nl, nl, nl, nxt + i, nl, nl, nl)
        idx = text.find("</Verilog>")
        if idx < 0:
            print("     [!!] 找不到 </Verilog>")
            ok = False
            continue
        line_start = text.rfind(nl, 0, idx) + len(nl)
        text = text[:line_start] + block + text[line_start:]
        if apply:
            write_text(path, text, enc, bom)
            print("     -> 已写入（%s%s）" % (enc, ", BOM" if bom else ""))
    return ok


def main():
    apply = "--apply" in sys.argv
    print("=" * 74)
    print(" lab4: SC500CS -> SC520CS 移植%s" % ("" if apply else "（dry-run）"))
    print("=" * 74)
    results = []
    for name, fn in [("1. 复制 SC520 配置表", step_copy),
                     ("2. design_top_wrapper.v", step_top),
                     ("3. uiisp_beta/ae_set.v", step_ae_set),
                     ("4. 时序约束 sdc", step_sdc),
                     ("5. TD 工程文件登记", step_register)]:
        print()
        print("-" * 74)
        print(name)
        results.append(fn(apply))
    print()
    print("=" * 74)
    print("全部步骤%s" % ("成功" if all(results) else "有失败项，见上面 [!!]"))
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
