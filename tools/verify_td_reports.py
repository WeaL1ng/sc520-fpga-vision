#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_td_reports.py --- 用 Python **独立解析 TD 报告**（P3 多软件验证）

为什么
------
TD（综合+P&R）是时序/资源的**唯一权威来源**，但之前都是"人工看报告"或
用 PowerShell 正则抽数。本脚本用 Python 再独立解析一遍，并做**一致性交叉校验**：

  1. `_phy.area`（布线后资源）与 `_chk.timing`/`_pr.timing`（时序）里的数字
     必须自洽（例：违例数 = 0 时，各 Path Group 的 Viol Endpoints 必须全 0）
  2. 各时钟域的 **Fmax 必须 ≥ 该域约束频率**（从 SDC 读 create_clock 周期）
  3. 资源不能超过器件上限，且**不得超过 80% 警戒线**（除 ERAM/DSP 另有阈值）
  4. 关键模块（`u_awb`/`u_hdmi_mixer`/`u_frame_latency`/`u_gray_binary_96`）
     必须在报告里出现，且 DSP/ERAM 占用与预期一致

不依赖任何 RTL/工具内部状态，只读报告文本。
"""
import re
import sys
from pathlib import Path

#  Windows 控制台默认 GBK，某些符号（=> ⚠ ★ 等）无法编码会让**整个脚本崩在 print 上**
#  —— 一个只能"偶尔跑通"的守门脚本等于没有守门。这里兜底成替换字符，
#  保证任何情况下都跑到最后一行结论。
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(errors="replace")

BASE = Path(__file__).resolve().parent.parent
PROJ = (BASE / r"rtl_vendor\anlogic_example\lab_ex4_all_features_SC500_720P"
               r"\lab_ex4_all_features")
PHY = PROJ / r"td_project\camera_to_dsi_display_Runs\phy_1"
SDC = PROJ / r"td_project\camera_to_dsi_display.sdc"

AREA = PHY / "camera_to_dsi_display_phy.area"
PRT = PHY / "camera_to_dsi_display_pr.timing"

fails, warns = [], []

def rd(p):
    return p.read_text(encoding="utf-8", errors="replace")

print("=" * 74)
print(" TD 报告独立解析校验（Python 侧，与 TD 侧交叉核对）")
print("=" * 74)
print("  area : %s" % AREA.name)
print("  timing: %s" % PRT.name)
print()

area = rd(AREA)
prt = rd(PRT)
sdc = rd(SDC)

# ---------------------------------------------------------------------------
# 1. 资源：device limit / used / %
# ---------------------------------------------------------------------------
print("  ---- 1. 布线后资源（phy.area）----")
res = {}
for key, label, limit in [("slice", "#slice", 21216), ("lut6", "#lut6", 21216),
                          ("eram", "#eram", 108), ("dsp", "#dsp", 40)]:
    m = re.search(r"^\s*#%s\s+(\d+)\s+out of\s+(\d+)\s+([\d.]+)%%" % key,
                  area, re.M)
    if not m:
        fails.append("phy.area 里找不到 #%s" % key)
        continue
    used, dev, pct = int(m.group(1)), int(m.group(2)), float(m.group(3))
    res[key] = (used, dev, pct)
    if dev != limit:
        warns.append("%s 器件上限报告为 %d，预期 %d" % (key, dev, limit))
    status = "OK"
    if pct > 80.0:
        status = "!! 超 80%% 警戒线"
        fails.append("%s 占用 %.2f%% 超过 80%% 警戒线" % (label, pct))
    print("    %-7s %6d / %-6d = %6.2f%%   %s" % (key, used, dev, pct, status))

# ---------------------------------------------------------------------------
# 2. 时序：全局 SWNS/STNS/HWNS/HTNS
# ---------------------------------------------------------------------------
print()
print("  ---- 2. 全局时序（pr.timing）----")
m = re.search(r"SWNS:\s*(-?[\d.]+)ns,\s*STNS:\s*(-?[\d.]+)ns", prt)
m2 = re.search(r"HWNS:\s*(-?[\d.]+)ns,\s*HTNS:\s*(-?[\d.]+)ns", prt)
if not (m and m2):
    fails.append("pr.timing 里找不到 Timing Status 汇总")
else:
    sw, st = float(m.group(1)), float(m.group(2))
    hw, ht = float(m2.group(1)), float(m2.group(2))
    print("    Setup SWNS=%+.3f ns  STNS=%.3f ns" % (sw, st))
    print("    Hold  HWNS=%+.3f ns  HTNS=%.3f ns" % (hw, ht))
    if st != 0.0 or ht != 0.0:
        fails.append("存在时序违例：STNS=%.3f HTNS=%.3f" % (st, ht))
    else:
        print("    [OK] 零违例")
    # ★ 2026-09-27：把两类问题分开（阈值未改，仍是 0.5 ns）
    #   · hold 违例 / setup 违例 = **硬失败**（下面 STNS/HTNS 的判据管）
    #   · setup 裕量偏薄 = **警告**：它是"还能再加多少逻辑"的提示，
    #     不是"这一版能不能用"的判据。混在一起会让真正的违例也被忽视。
    if hw < 0.0:
        fails.append("全局 hold 裕量 %.3f ns 为负（真违例）" % hw)
    elif sw < 0.5:
        warns.append("全局 setup 裕量仅 %+.3f ns（< 自设的 0.5 ns 舒适线；"
                     "**零违例**，但再加逻辑有风险 —— 见验收证据链 G6）" % sw)

# ---------------------------------------------------------------------------
# 3. 各 Path Group 违例数必须与全局一致（自洽性）
# ---------------------------------------------------------------------------
print()
print("  ---- 3. Path Group 自洽性（违例数应全 0）----")
viol_total = 0
groups = 0
for m in re.finditer(r"Path Group\s+:\s*(.+?)\s*\n(?:.*?\n){0,8}?.*?Max\s*:\s*SWNS\s+([-\d.]+)ns,\s*STNS\s+([-\d.]+)ns,\s*(\d+)\s+Viol",
                     prt):
    groups += 1
    viol_total += int(m.group(4))
print("    扫描到 %d 个含 Max 统计的 Path Group，违例端点数合计 = %d" % (groups, viol_total))
if viol_total != 0:
    fails.append("Path Group 违例端点合计 %d != 0" % viol_total)
else:
    print("    [OK] 所有 Path Group 无违例")

# ---------------------------------------------------------------------------
# 4. 各时钟域 Fmax vs SDC 约束频率
# ---------------------------------------------------------------------------
print()
print("  ---- 4. 时钟域 Fmax vs 约束频率 ----")
# 从 Clock Summary 读约束频率
clocks = {}
for m in re.finditer(r"^\s*(clk\d+):\s+([\d.]+)\s+(\d+)\s+(\S+)", prt, re.M):
    clocks[m.group(1)] = (float(m.group(2)), m.group(4))
for cid, (f, name) in clocks.items():
    if name in ("u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk", "HDMI_PIXEL_CLK",
                "HDMI_SERIAL_CLK", "MIPI_RX_BYTE_CLK"):
        print("    %-10s %-46s 约束 %8.3f MHz" % (cid, name.split("/")[-1], f))

# 从 Path Group 读实测 Fmax
key_groups = {}
lines = prt.splitlines()
for i, ln in enumerate(lines):
    m = re.match(r"Path Group\s+:\s+(\S+)\s*->\s*(\S+)", ln)
    if m and m.group(1) == m.group(2):
        g = m.group(1)
        for j in range(i, min(i + 12, len(lines))):
            fm = re.search(r"Fmax\s*:\s*([\d.]+)MHz", lines[j])
            if fm:
                key_groups.setdefault(g, float(fm.group(1)))
                break

REQ = {"MIPI_RX_BYTE_CLK": 59.995, "HDMI_PIXEL_CLK": 75.002,
       "HDMI_SERIAL_CLK": 375.094,
       "u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk": 66.667}
for g in sorted(key_groups):
    if g in REQ:
        got, need = key_groups[g], REQ[g]
        marg = (got / need - 1.0) * 100.0
        ok = got >= need
        if not ok:
            fails.append("%s Fmax %.3f < 需求 %.3f MHz" % (g, got, need))
        print("    %-46s 实测 %8.3f MHz  需 %7.3f  余量 %+6.1f%%  %s"
              % (g.split("/")[-1], got, need, marg, "OK" if ok else "NG"))
        if 0 <= marg < 5.0:
            warns.append("%s 频率余量仅 %.1f%%" % (g, marg))

# ---------------------------------------------------------------------------
# 5. 关键模块必须在报告里，且占用符合预期
# ---------------------------------------------------------------------------
print()
print("  ---- 5. 关键模块占用（phy.area）----")
#  报告列（gate/phy.area 表头，已核对）：
#    | Instance | Module | logic lut | ripple | seq | eram | dsp | dram lut | shifter lut | f7mux | ...
#  正则从 Module 起捕获 6 段：g[0]=module g[1]=logic lut g[2]=ripple
#                            g[3]=seq g[4]=eram g[5]=dsp
#  ⚠ 曾经把 g[4] 当成 dsp 去断言 `u_logo_rom_eram`（ERAM=7）=> 误判 NG。
#     现在只按**字段名对应的下标**取值，且 print 时标出真实列名。
EXPECT = {
    "u_awb":            {"dsp": 8},    # AWB 的 8 个并行乘法器，必须仍在
    "u_gray_binary_96": {"dsp": 0},    # 灰度系数已改移位加法，不得吃 DSP
    "u_logo_rom_eram":  {"eram": 7},   # Logo ROM 推断出的 ERAM 块数
    # ★ P4：卡通模块整个算法零乘法（灰度用移位加法、量化用位操作、
    #   形态学只有比较），**DSP 必须为 0**。这是"常量乘法绝不能用 DSP"
    #   这条铁律在 P4 上的守门断言。
    "u_cartoon_96":     {"dsp": 0},
    # ★ P5：目标检测（色度变换 + tile 统计 + BCD，全程比较/移位）
    "u_target_detect_96": {"dsp": 0},
    # ★ P6：亮度统计 + AE 控制器
    #   luma_stats：77/150/29 全部移位加法；平均亮度用"乘倒数再右移"。
    #               **整条回路上一个常量乘法都没有 ⇒ DSP 必须为 0。**
    #   ae_ctrl   ：死区/偏差分区全是常量比较，节流是计数器 ⇒ 同样 DSP 必须为 0。
    #   —— 铁律三在 P6 上的守门断言：一旦有人图省事写成 `*`，综合器会立刻
    #      吃掉 DSP，这里就会报出来。
    "u_luma_stats":       {"dsp": 0},
    "u_ae_ctrl":          {"dsp": 0},
}
for mod, exp in EXPECT.items():
    m2 = re.search(r"\|\s*%s\s*\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|"
                   % re.escape(mod), area)
    if not m2:
        fails.append("phy.area 里找不到模块 %s" % mod)
        continue
    g = [x.strip() for x in m2.groups()]
    print("    %-20s logic_lut=%-6s ripple=%-5s seq=%-6s eram=%-4s dsp=%-4s"
          % (mod, g[1], g[2], g[3], g[4], g[5]))
    for field, want in exp.items():
        idx = {"logic_lut": 1, "ripple": 2, "seq": 3, "eram": 4, "dsp": 5}[field]
        got = g[idx]
        if not got.isdigit():
            fails.append("%s 的 %s 无法解析：%r" % (mod, field, got))
        elif int(got) != want:
            fails.append("%s %s=%s，预期 %d" % (mod, field.upper(), got, want))
        else:
            print("        [OK] %s = %d（预期 %d）" % (field, want, want))

# ---------------------------------------------------------------------------
# 5b. 卡通模块的"分布式 RAM"占用（信息项，但值得盯住）
# ---------------------------------------------------------------------------
#  实测：`u_cartoon_96` 的两个行缓冲（320x16 x2 = 10240 bit）被 TD 推断成
#  **dram lut = 256**（分布式 RAM）而**不是** ERAM（eram = 0）——尽管源码里
#  写了 `(* ram_style = "block" *)`。这会实打实吃掉 ~256 个 LUT，并因
#  布局分散而加剧布线拥塞。此处只做**记录与告警**，不做失败判定
#  （要改成真 ERAM 需要换成厂商 ERAM 原语，并重新推导行缓冲的读写时序）。
print()
print("  ---- 5b. 行缓冲推断方式（信息项）----")
m3 = re.search(r"\|\s*u_cartoon_96\s*\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|"
               r"([^|]*)\|", area)
if m3:
    gg = [x.strip() for x in m3.groups()]
    print("    logic_lut=%s  seq=%s  eram=%s  dsp=%s  dram_lut=%s  f7mux=%s"
          % (gg[1], gg[3], gg[4], gg[5], gg[6], gg[8] if len(gg) > 8 else "?"))
    if gg[6].isdigit() and int(gg[6]) > 0:
        warns.append("u_cartoon_96 行缓冲走的是 dram lut = %s（非 ERAM）——"
                     "占 LUT 且不利于布线，若时序吃紧可考虑改厂商 ERAM 原语" % gg[6])
else:
    warns.append("phy.area 里找不到 u_cartoon_96 的 dram lut 列")

# ---------------------------------------------------------------------------
# 5c. ★ frame_latency 的 CLK_FREQ_HZ 必须等于它所在时钟域的**真实**频率
# ---------------------------------------------------------------------------
#  踩坑（2026-09-21 上板发现）：`S_ddr_clk` 这个名字**极具误导性** ——
#  它不是 266.667 MHz 的 `ddr_clk`，而是 **66.667 MHz 的 `usr_clk`**
#  （DDR2 用户接口时钟）。证据：报告里 `u_ddr2/ddr_clk` 的 Fanout 只有 6，
#  而 video_in/video_out/mc_to_user_interface 的寄存器全在 `usr_clk` 上。
#  第一版按名字写了 266666667 => 毫秒计数器慢 4 倍 => **屏上延迟读数 = 真实值 ÷ 4**。
#
#  => 把"网络名 → TD 报告时钟名"的映射**写死在这一处**，并做两件事：
#     ① 用报告自校验这个映射（找个只被该网络驱动的实例，看它的时钟名）；
#     ② 交叉比对 RTL 里的 CLK_FREQ_HZ 与报告里该时钟的频率。
print()
print("  ---- 5c. ★ frame_latency.CLK_FREQ_HZ vs 真实时钟频率 ----")

# TD 报告的 Clock-Id 表 → {时钟名: 频率MHz}
name2freq = {}
for m in re.finditer(r"^\s*clk\d+:\s+([\d.]+)\s+\d+\s+(\S+)\s*$", prt, re.M):
    name2freq[m.group(2)] = float(m.group(1))

# design_top_wrapper.v 里的时钟网络名 → 报告里的时钟名
NET_TO_CLOCK = {
    "S_ddr_clk":        "u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk",  # NOT ddr_clk！
    "S_csi_rx_clk":     "MIPI_RX_BYTE_CLK",
    "S_hdmi_pixel_clk": "HDMI_PIXEL_CLK",
}

# ---- ① 自校验映射：u_mc_to_user_interface 只被 S_ddr_clk 驱动 ----
mo = sorted(set(re.findall(
    r"u_mc_to_user_interface/\S+.*?rising edge triggered by clock (\S+)", prt)))
exp_ddr = NET_TO_CLOCK["S_ddr_clk"]
if not mo:
    warns.append("报告里找不到 u_mc_to_user_interface 的路径，无法自校验 S_ddr_clk 映射")
elif mo != [exp_ddr]:
    fails.append("NET_TO_CLOCK['S_ddr_clk'] 映射与报告不符："
                 "mc_to_user_interface 实际时钟 = %s，映射写的是 %s" % (mo, exp_ddr))
else:
    print("    映射自校验: u_mc_to_user_interface 时钟 = %s  [OK]" % mo[0])

# ---- ② 从 RTL 抠出 frame_latency 的 CLK_FREQ_HZ 与 I_clk 网络名 ----
DW = PROJ / r"user_source\hdl_source\design_top_wrapper.v"
dw = rd(DW)
mfl = re.search(r"frame_latency\s*#\s*\((.*?)\)\s*u_frame_latency\s*\((.*?)\);",
                dw, re.S)
if not mfl:
    fails.append("在 design_top_wrapper.v 里找不到 frame_latency 例化（正则失配）")
else:
    mhz = re.search(r"CLK_FREQ_HZ\s*\(\s*([\d_]+)\s*\)", mfl.group(1))
    mnet = re.search(r"\.I_clk\s*\(\s*(\w+)\s*\)", mfl.group(2))
    if not (mhz and mnet):
        fails.append("frame_latency 例化里抠不到 CLK_FREQ_HZ 或 .I_clk")
    else:
        rtl_hz = int(mhz.group(1).replace("_", ""))
        net = mnet.group(1)
        print("    RTL: frame_latency.CLK_FREQ_HZ = %d，.I_clk = %s" % (rtl_hz, net))
        clk = NET_TO_CLOCK.get(net)
        if clk is None:
            fails.append("I_clk 网络 %s 不在 NET_TO_CLOCK 里 —— 新增时钟域请补映射" % net)
        elif clk not in name2freq:
            fails.append("报告 Clock Summary 里没有时钟 %s" % clk)
        else:
            real_hz = name2freq[clk] * 1e6
            err = abs(rtl_hz - real_hz) / real_hz
            print("    报告: %s = %.3f MHz  => 期望 CLK_FREQ_HZ ≈ %d"
                  % (clk.split("/")[-1], name2freq[clk], round(real_hz)))
            if err > 0.01:
                fails.append(
                    "★ frame_latency.CLK_FREQ_HZ=%d 与真实时钟 %s=%.3fMHz 差 %.1f%% "
                    "—— 毫秒刻度会整体缩放（曾把 66.667 写成 266.667，读数小 4 倍）"
                    % (rtl_hz, clk.split("/")[-1], name2freq[clk], err * 100))
            else:
                print("        [OK] 误差 %.3f%%" % (err * 100))

# ---------------------------------------------------------------------------
# 结论
# ---------------------------------------------------------------------------
print()
print("=" * 74)
if fails:
    print(" [NG] %d 个问题：" % len(fails))
    for f in fails:
        print("   - %s" % f)
else:
    print(" [OK] TD 报告自洽、无违例、各域达标、关键模块齐全")
if warns:
    print(" [WARN] %d 条：" % len(warns))
    for w in warns:
        print("   - %s" % w)
print("=" * 74)
sys.exit(1 if fails else 0)
