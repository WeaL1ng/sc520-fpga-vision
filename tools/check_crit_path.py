# -*- coding: utf-8 -*-
"""精确取出 slack 等于全局 SWNS 的那条路径的完整分解。

★ 为什么不能"按 slack 排序取最小"：报告里混着 **ERAM 写入口的内部建立检查**
  （Logic Level 1 / ERAM=1 / data path 仅 0.2~0.36 ns），它们的 slack 比全局
  SWNS 还小，却不属于时钟到时钟的路径 ⇒ 排序取最小会抓错对象。
  必须**按全局 SWNS 的数值**去定位那条真正的关键路径。
"""
import io
import os
import re
import sys

BASE = (r"rtl_vendor\anlogic_example\lab_ex4_all_features_SC500_720P"
        r"\lab_ex4_all_features")
TIM = os.path.join(BASE, r"td_project\camera_to_dsi_display_Runs\phy_1"
                         r"\camera_to_dsi_display_pr.timing")
txt = io.open(TIM, encoding="utf-8", errors="replace").read()
lines = txt.split("\n")

# 全局 SWNS
m = re.search(r"SWNS:\s*(-?[\d.]+)ns", txt)
if not m:
    m = re.search(r"Max\s*:\s*SWNS\s*(-?[\d.]+)ns", txt)
if not m:
    print("[NG] 找不到全局 SWNS"); sys.exit(1)
sw = m.group(1)
print("全局 SWNS = %s ns（用这个数值去定位关键路径）" % sw)

# 找 slack 等于该值、且**不是** ERAM 内部检查的路径
hits = 0
i = 0
while i < len(lines) and hits < 3:
    if re.search(r"Slack\s*:\s*%sns" % re.escape(sw), lines[i]):
        blk = lines[i:i + 14]
        joined = "\n".join(blk)
        # 排除 ERAM 写入口内部检查（Logic Level 1 且只含 ERAM）
        if re.search(r"Logic Level\s*:\s*1\s*\(\s*ERAM=1", joined):
            i += 1
            continue
        hits += 1
        print("\n" + "=" * 78)
        print(" 关键路径 #%d" % hits)
        print("=" * 78)
        for s in blk:
            if re.search(r"Slack|Begin Point|End Point|Data Path Delay|Logic Level|"
                         r"Max Fanout|Check Type|Budget|Clock Skew|Path Type|"
                         r"triggered by clock", s):
                print("  " + s.strip()[:150])
        # 判型
        mm = re.search(r"cell\s*([\d.]+)ns\s*\((\d+)%\),\s*net\s*([\d.]+)ns\s*\((\d+)%\)",
                       joined)
        if mm:
            cell, cp, net, np_ = mm.group(1), int(mm.group(2)), mm.group(3), int(mm.group(4))
            print("\n  ---- 判型 ----")
            print("  cell %s ns (%d%%)   net %s ns (%d%%)" % (cell, cp, net, np_))
            if np_ >= 50:
                print("  => **布线拥塞型**：加流水只缩逻辑深度，对净延迟无效，很可能收不到余量。")
                print("     该做的是降扇出 / 切断跨模块长连线 / 削同域组合面积。")
            else:
                print("  => **逻辑深度型**：加流水对症，预计能收回大部分余量。")
    i += 1

if hits == 0:
    print("[NG] 没找到非 ERAM 内部检查、且 slack = %s 的路径" % sw)
    print("     可试：在报告里搜 'Slack : %sns' 手工看上下文" % sw)
