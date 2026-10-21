#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
dump_osd_font.py --- 把 osd_char_lib.v 里的字形反解成 ASCII 图

目的：在新增字形之前，先量出**现有字形的真实列宽约定**，
      避免新字形与旧字形宽度不一致（会导致新文本与 Logo/CNT 观感不统一）。

输出：
  - 每个字符的 8x16 点阵，用 '#' / '.' 表示
  - 每行有效列的统计（help 判断列宽约定是 8 / 12 / 16）
"""
import re
import sys
from pathlib import Path

LIB = (Path(__file__).resolve().parent.parent
       / "rtl_vendor" / "anlogic_example"
       / "lab_ex4_all_features_SC500_720P" / "lab_ex4_all_features"
       / "user_source" / "hdl_source" / "osd_char_lib.v")

src = LIB.read_text(encoding="utf-8", errors="replace")

# 1) localparam CHAR_XX = 8'hNN;
consts = {}
for m in re.finditer(r"localparam\s+CHAR_(\w+)\s*=\s*8'h([0-9a-fA-F]{2})\s*;", src):
    consts["CHAR_" + m.group(1)] = int(m.group(2), 16)

# 2) CHAR_XX: begin ... case(I_row) 4'dN: O_row_bits = 16'hXXXX; ... endcase end
blocks = {}
for m in re.finditer(
        r"(CHAR_\w+)\s*:\s*begin(.*?)endcase\s*end", src, re.S):
    name, body = m.group(1), m.group(2)
    rows = {}
    for rm in re.finditer(r"4'd(\d+)\s*:\s*O_row_bits\s*=\s*16'h([0-9a-fA-F]{4})", body):
        rows[int(rm.group(1))] = int(rm.group(2), 16)
    if rows:
        blocks[name] = rows

print("字符常量: %d 个   已解析字形: %d 个" % (len(consts), len(blocks)))
print()

# 3) 打印并统计列宽
max_used = 0
report = []
for name in sorted(blocks, key=lambda n: consts.get(n, 0)):
    code = consts.get(name, -1)
    rows = blocks[name]
    disp = chr(code) if 0x20 <= code < 0x7f else "<%02X>" % code
    print("CHAR_%-6s = 0x%02X  %s" % (name.replace("CHAR_", ""), code, disp))
    used = 0
    for r in range(16):
        bits = rows.get(r, 0)
        line = "".join("#" if (bits >> (15 - c)) & 1 else "." for c in range(16))
        # 该行最右的 '#' 位置（从 0 开始）
        right = max([c for c in range(16) if (bits >> (15 - c)) & 1], default=-1)
        used = max(used, right + 1)
        print("    %2d |%s|" % (r, line))
    print("       有效列数 = %d" % used)
    print()
    report.append((name, code, used))
    max_used = max(max_used, used)

print("=" * 60)
print("所有字形的最大有效列数 = %d" % max_used)
print("列宽分布：")
from collections import Counter
for w, n in sorted(Counter(u for _, _, u in report).items()):
    print("   %2d 列 : %d 个字符" % (w, n))
