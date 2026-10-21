#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_pin_assign.py --- 引脚约束的**独立**静态校验（P7 之前补的守门脚本）

为什么需要
----------
扩展(3) 给设计新增了 5 个顶层输出（4 个 LED + 蜂鸣器），每个都要在 `pin.adc` 里
指定一个物理 LOCATION。**写错 LOCATION 的后果不是"功能不对"，而是**：

  · 撞上已被占用的引脚（DDR / MIPI / TMDS / 摄像头）⇒ 轻则布线失败，
    重则**两个驱动器对顶**，是真正可能伤板子的错误；
  · 撞上同一文件里另一个信号 ⇒ TD 报错或（更糟）静默地只保留一个；
  · 写了一个板上并不存在的 FPGA 引脚 ⇒ 布局阶段才失败，白等十几分钟。

这类错误**仿真查不出、综合也查不出**，只能靠"独立地把约束文件解析一遍"。
本脚本因此做四件事：

  1. **同一 LOCATION 是否被赋给多个信号**（跨项目里所有 .adc 文件一起查）；
  2. 本项目新增的 5 个信号是否**恰好各有一条**赋值；
  3. 新信号的 LOCATION 是否与"关键既有引脚"（DDR/MIPI/TMDS/摄像头/按键/时钟）冲突；
  4. 顶层端口里有没有**忘记约束**的（漏约束会在布局阶段报错，早发现早好）。

用法
----
    python tools\\verify_pin_assign.py            # exit 0 = 通过
"""
import os
import re
import sys

BASE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                    r"rtl_vendor\anlogic_example\lab_ex4_all_features_SC500_720P\lab_ex4_all_features")
PIN = os.path.join(BASE, r"user_source\constraints_source\pin.adc")
DDR = os.path.join(BASE, r"user_source\hdl_source\ph1p35_ddr\ddr2\src\adc\ddr2.adc")
TOP = os.path.join(BASE, r"user_source\hdl_source\design_top_wrapper.v")

# 本次新增（扩展(3)）必须存在的信号
NEW_SIGS = ["O_led[0]", "O_led[1]", "O_led[2]", "O_led[3]", "O_buzzer"]
# 板上引脚分配表里的 LED/蜂鸣器（HX1P35B 引脚分配汇总 §二 / §十一）
EXPECT_LOC = {
    "O_led[0]": "D10", "O_led[1]": "E10", "O_led[2]": "C6",
    "O_led[3]": "D6",  "O_buzzer": "C12",
}

ASSIGN = re.compile(
    r"set_pin_assignment\s*\{\s*([^}]+?)\s*\}\s*\{\s*(.*?)\s*\}",
    re.I | re.S)
#  DDR/高速引脚用的是 IP 坐标命名空间（X0Y44Z2），与封装引脚名（D10）不是同一套
#  ⇒ 两个命名空间天然不可能"同名冲突"，但要**数出来**，避免脚本静默漏看。
ASSIGN_IPPIN = re.compile(
    r"set_ippin_assignment\s*\{\s*([^}]+?)\s*\}\s*\{\s*(.*?)\s*\}",
    re.I | re.S)
LOC = re.compile(r"LOCATION\s*=\s*([A-Za-z]+\d+)", re.I)
LOC_IP = re.compile(r"LOCATION\s*=\s*(X\d+Y\d+Z\d+)", re.I)


def parse(path):
    """返回 [(signal, loc, raw)]；非 set_pin_assignment 的行忽略。"""
    if not os.path.exists(path):
        return [], 0
    txt = open(path, encoding="utf-8", errors="replace").read()
    out = []
    for m in ASSIGN.finditer(txt):
        sig = m.group(1).strip()
        body = m.group(2)
        lm = LOC.search(body)
        if lm:
            out.append((sig, lm.group(1).upper(), m.group(0)))
    n_ip = len(ASSIGN_IPPIN.findall(txt))
    return out, n_ip


def main():
    bad = 0
    pin, _ = parse(PIN)
    ddr, ddr_ip = parse(DDR)
    print("=" * 72)
    print(" 引脚约束静态校验（独立解析 .adc，不依赖 TD）")
    print("=" * 72)
    print("  pin.adc 赋值条数 = %d，ddr2.adc 封装引脚 = %d，DDR IP 坐标引脚 = %d"
          % (len(pin), len(ddr), ddr_ip))
    print("  （DDR 用 X0Y44Z2 这类 IP 坐标，与 D10 这类封装引脚名不冲突，故分开统计）")

    # ---- ① 跨文件同一 LOCATION 冲突 ----
    print()
    print(" ---- 1. 同一 LOCATION 是否被多个信号占用 ----")
    by_loc = {}
    for src, rows in (("pin.adc", pin), ("ddr2.adc", ddr)):
        for sig, loc, _ in rows:
            by_loc.setdefault(loc, []).append("%s(%s)" % (sig, src))
    dup = {k: v for k, v in by_loc.items() if len(v) > 1}
    #  允许"同一 LOCATION 出现在同一信号的多个文件里"这种重复描述
    real_dup = {}
    for k, v in dup.items():
        names = set(x.split("(")[0] for x in v)
        if len(names) > 1:
            real_dup[k] = v
    if real_dup:
        for k, v in sorted(real_dup.items()):
            print("   [NG] %-5s 被多个信号占用：%s" % (k, ", ".join(v)))
        bad += len(real_dup)
    else:
        print("   [OK] 没有任何物理引脚被两个不同信号同时占用")

    # ---- ② 新增信号恰好各一条，且 LOCATION 与引脚表一致 ----
    print()
    print(" ---- 2. 扩展(3) 的 5 个新信号 ----")
    got = {}
    for sig, loc, _ in pin:
        if sig in EXPECT_LOC:
            got.setdefault(sig, []).append(loc)
    for sig in NEW_SIGS:
        locs = got.get(sig, [])
        if len(locs) != 1:
            print("   [NG] %-11s 赋值条数 = %d（应为 1）" % (sig, len(locs)))
            bad += 1
        elif locs[0] != EXPECT_LOC[sig]:
            print("   [NG] %-11s LOCATION=%s，引脚分配表要求 %s"
                  % (sig, locs[0], EXPECT_LOC[sig]))
            bad += 1
        else:
            print("   [OK] %-11s LOCATION=%s（与 HX1P35B 引脚分配表一致）"
                  % (sig, locs[0]))

    # ---- ③ 新信号不能撞上关键既有引脚 ----
    print()
    print(" ---- 3. 新信号是否撞上关键既有引脚 ----")
    critical = {}
    for sig, loc, _ in pin:
        if sig in EXPECT_LOC:
            continue
        critical[loc] = sig
    hit = 0
    for sig in NEW_SIGS:
        loc = EXPECT_LOC[sig]
        if loc in critical:
            print("   [NG] %-11s (%s) 与既有信号 %s 撞引脚！" % (sig, loc, critical[loc]))
            hit += 1
    if hit == 0:
        print("   [OK] 5 个新引脚（D10/E10/C6/D6/C12）均未被既有信号占用")
    bad += hit

    # ---- ④ 顶层端口是否都有约束 ----
    print()
    print(" ---- 4. 顶层端口 vs 约束覆盖 ----")
    top = open(TOP, encoding="utf-8", errors="replace").read()
    head = top[:top.index(");")]
    ports = []
    for m in re.finditer(r"(input|output|inout)\s+wire\s*(\[[^\]]*\])?\s*([A-Za-z_]\w*)", head):
        ports.append(m.group(3))
    constrained = set()
    for sig, _, _ in pin + ddr:
        base = re.sub(r"\[\d+\]$", "", sig)
        constrained.add(base)
    #  由 IP/厂商约束提供的引脚（MIPI pad、DDR、TMDS 等）单独列，不算"漏约束"
    exempt_pref = ("IO_rx_", "ddr_", "O_tmds_")
    missing = [p for p in ports
               if p not in constrained and not p.startswith(exempt_pref)]
    n_new = sum(1 for p in ports if p in ("O_led", "O_buzzer"))
    print("   顶层端口 %d 个；其中扩展(3) 新增 %d 个" % (len(ports), n_new))
    if missing:
        print("   [NG] 下列端口在本项目 .adc 里找不到约束：%s" % ", ".join(missing))
        bad += 1
    else:
        print("   [OK] 除由 IP/厂商约束提供的 %s 之外，其余端口均有约束"
              % ", ".join(exempt_pref))

    print()
    print("=" * 72)
    print(" [OK] 引脚约束校验通过" if bad == 0 else " [NG] %d 处问题" % bad)
    print("=" * 72)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
