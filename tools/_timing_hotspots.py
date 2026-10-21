# -*- coding: utf-8 -*-
"""按"起止模块"聚合 pr.timing 里的负 slack 路径，判断流水改造的工作面。

用法: python _stage/_timing_hotspots.py <pr.timing>
"""
import re
import sys
from collections import Counter

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

path = sys.argv[1]
lines = open(path, encoding="gbk", errors="replace").read().splitlines()

slack = None
begin = None
budget = None
delay = None
level = None
rows = []

for ln in lines:
    s = ln.strip()
    m = re.match(r"Slack\s+:\s+(-?[\d.]+)ns", s)
    if m:
        slack = float(m.group(1))
    m = re.match(r"Budget\s+:\s+([\d.]+)ns", s)
    if m:
        budget = float(m.group(1))
    m = re.match(r"Data Path Delay\s+:\s+([\d.]+)ns", s)
    if m:
        delay = float(m.group(1))
    m = re.match(r"Logic Level\s+:\s+(\d+)", s)
    if m:
        level = int(m.group(1))
    m = re.match(r"Begin Point\s+:\s+(\S+)", s)
    if m:
        begin = m.group(1)
    m = re.match(r"End Point\s+:\s+(\S+)", s)
    if m and slack is not None and slack < 0:
        rows.append((slack, begin or "", m.group(1), budget, delay, level))
        begin = None


def mod_of(point):
    """u_isp_top/u_awb/mult6_syn_165.clk -> u_isp_top/u_awb"""
    parts = point.split("/")
    return "/".join(parts[:2]) if len(parts) >= 2 else point


counter = Counter()
for slack, b, e, *_ in rows:
    counter[(mod_of(b), mod_of(e))] += 1

print("负 slack 路径条数（报告内抽样）: %d" % len(rows))
print()
print("按 起始模块 -> 结束模块 聚合（前 15）:")
for (a, c), n in counter.most_common(15):
    print("  %-34s -> %-34s %3d 条" % (a, c, n))
print()
print("最差的 10 条:")
seen = set()
for slack, b, e, budget, delay, level in sorted(rows, key=lambda r: r[0])[:40]:
    key = (b, e)
    if key in seen:
        continue
    seen.add(key)
    print("  slack %6.3f ns  budget %.3f  delay %.3f  level %s" % (slack, budget or 0, delay or 0, level))
    print("     %s" % b)
    print("  -> %s" % e)
    if len(seen) >= 10:
        break
