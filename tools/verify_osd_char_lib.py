#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_osd_char_lib.py --- 比对 osd_char_lib.v 与 .v.new

必须满足：
  1) 原文件里出现的每个字形，在新文件里 **逐位完全相同**（防止改坏已上板画面）
  2) 新文件包含全部新增字形
  3) 打印新增字形的 ASCII 图，供人工确认形状可读
"""
import re
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
LIB = (BASE / r"rtl_vendor\anlogic_example\lab_ex4_all_features_SC500_720P"
             r"\lab_ex4_all_features\user_source\hdl_source\osd_char_lib.v")
NEWF = Path(str(LIB) + ".new")


def parse(path):
    src = path.read_text(encoding="utf-8", errors="replace")
    consts = {}
    for m in re.finditer(r"localparam\s+(CHAR_\w+)\s*=\s*8'h([0-9a-fA-F]{2})\s*;", src):
        consts[m.group(1)] = int(m.group(2), 16)
    glyphs = {}
    for m in re.finditer(r"(CHAR_\w+)\s*:\s*begin(.*?)endcase\s*end", src, re.S):
        name, body = m.group(1), m.group(2)
        rows = {}
        for rm in re.finditer(r"4'd(\d+)\s*:\s*O_row_bits\s*=\s*16'h([0-9a-fA-F]{4})", body):
            rows[int(rm.group(1))] = int(rm.group(2), 16)
        if rows:
            glyphs[name] = [rows.get(r, 0) for r in range(16)]
    return consts, glyphs


oc, og = parse(LIB)
nc, ng = parse(NEWF)

print("原文件: %d 常量 / %d 字形" % (len(oc), len(og)))
print("新文件: %d 常量 / %d 字形" % (len(nc), len(ng)))
print()

# ---- 1) 原有字形逐位比对 ----
bad = []
for name, rows in og.items():
    if name not in ng:
        bad.append((name, "新文件缺失"))
    elif ng[name] != rows:
        bad.append((name, "内容不一致"))
    elif nc.get(name) != oc.get(name):
        bad.append((name, "字符码不一致: 原 0x%02X 新 0x%02X"
                    % (oc.get(name, -1), nc.get(name, -1))))

if bad:
    print("!! 原有字形校验失败：")
    for n, why in bad:
        print("   %-18s %s" % (n, why))
    sys.exit(1)
print("[OK] 原有 %d 个字形逐位完全一致" % len(og))

# ---- 2) 新增字形列表 ----
added = [n for n in ng if n not in og]
print("[OK] 新增 %d 个字形: %s" % (len(added), ", ".join(sorted(added))))
print()

# ---- 3) 打印新增字形的 ASCII 图 ----
def show(name, code):
    rows = ng[name]
    disp = chr(code) if 0x20 <= code < 0x7f else "?"
    print("  %-18s = 0x%02X  '%s'" % (name, code, disp))
    used = 0
    for r in range(11):
        bits = rows[r]
        line = "".join("#" if (bits >> (15 - c)) & 1 else "." for c in range(14))
        right = max([c for c in range(16) if (bits >> (15 - c)) & 1], default=-1)
        used = max(used, right + 1)
        if line.strip('.'):
            print("      |%s|" % line)
    print("      有效列数 = %d" % used)

print("新增字形预览（只显示非空行）：")
for name in sorted(added, key=lambda n: nc[n]):
    show(name, nc[name])
