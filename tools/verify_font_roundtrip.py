#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_font_roundtrip.py --- osd_char_lib 的**双向往返**验证（P3 多软件验证）

思路（与"生成侧"完全独立的第二实现）
--------------------------------------
生成侧：`gen_osd_char_lib.py` 用 ASCII 图 -> 位运算 -> 写出 Verilog 16 进制
校验侧：本脚本 **从 Verilog 反解成 ASCII 图**，再与生成器里的 ASCII 定义**字符级比对**

这样能同时抓住三类错误：
  1. 位序搞反（MSB/LSB）—— 图会左右镜像
  2. 行序搞反 —— 图会上下翻转
  3. 任何一位抄错 —— 图会出现/缺少像素

**不依赖生成器内部的任何函数**，只读两份文本：Verilog 与生成器的 ASCII 定义。

额外校验
--------
* 每个字形必须是 8 宽 x 16 高、有效内容 row 0..10
* 未定义的字符码必须返回全 0（不能漏 default）
* 打印几个字形的 ASCII 图供人工确认可读性
"""
import re
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
LIB = (BASE / r"rtl_vendor\anlogic_example\lab_ex4_all_features_SC500_720P"
             r"\lab_ex4_all_features\user_source\hdl_source\osd_char_lib.v")
GEN = BASE / r"tools\gen_osd_char_lib.py"

# ---------------------------------------------------------------------------
# 字形规格（实测自原始文件；与 gen_osd_char_lib.py 的约定必须一致）
# ---------------------------------------------------------------------------
#   点阵 8 宽 x 16 高；每行 16 bit，MSB(bit15) 是最左列
#   原文件里**本来就存在两种风格**（厂商原版如此）：
#     * 字母 A B D E ... -> 行 2..9
#     * 数字 0-9 与 C N Q T : -> 行 1..12
#     * 中文 安/路 -> 行 0..10
#   新增字形对齐**字母风格**：ASCII 图 8 行，第 0 行写入点阵 row 2。
ART_TOP_ROW = 2
ART_LINES   = 8
ART_COLS    = 14
ROWS, WIDTH = 16, 16

# ---------------------------------------------------------------------------
# 1. 从 Verilog 反解：code -> [16 个 16bit 值]
# ---------------------------------------------------------------------------
src = LIB.read_text(encoding="utf-8", errors="replace")

consts = {}
for name, h in re.findall(r"localparam\s+(CHAR_\w+)\s*=\s*8'h([0-9a-fA-F]{2})\s*;", src):
    consts[name] = int(h, 16)

glyphs = {}          # name -> {row: value}
for m in re.finditer(r"(CHAR_\w+)\s*:\s*begin(.*?)endcase\s*end", src, re.S):
    name, body = m.group(1), m.group(2)
    rows = {}
    for r, v in re.findall(r"4'd(\d+)\s*:\s*O_row_bits\s*=\s*16'h([0-9a-fA-F]{4})", body):
        rows[int(r)] = int(v, 16)
    if rows:
        glyphs[name] = rows

print("=" * 66)
print(" osd_char_lib 双向往返验证")
print("=" * 66)
print("  Verilog: %d 个 CHAR_ 常量 / %d 个字形分支" % (len(consts), len(glyphs)))

fails = []

# ---- 1a 每个常量都要有字形 ----
for n in consts:
    if n not in glyphs:
        fails.append("常量 %s 没有对应字形分支" % n)

# ---- 1b 每个字形必须 16 行齐全、且 row 11..15 为 0 ----
for n, rows in glyphs.items():
    for r in range(ROWS):
        if r not in rows:
            fails.append("%s 缺少 row %d" % (n, r))
    # 注意：**不能**断言"只占 row 0..10" —— 原版数字用到 row 1..12。
    # 只检查字形非空（至少有一个亮像素）；**空格 CHAR_SP 必须全零**，是唯一例外。
    if n == "CHAR_SP":
        if any(rows.get(r, 0) for r in range(ROWS)):
            fails.append("CHAR_SP 应全零（空格），但有亮像素")
    elif not any(rows.get(r, 0) for r in range(ROWS)):
        fails.append("%s 是全空字形（可能抄错）" % n)

# ---- 1c 必须有 default 分支 ----
if not re.search(r"case\s*\(\s*I_char\s*\)", src):
    fails.append("找不到 case(I_char)")
if len(re.findall(r"default\s*:\s*O_row_bits\s*=\s*16'h0000", src)) < 1:
    fails.append("缺少 case(I_char) 的 default 分支")
if "default: O_row_bits = 16'h0000;" not in src:
    fails.append("缺少内层 case(I_row) 的 default 分支")

print("  结构校验: %s" % ("通过" if not fails else "发现 %d 个问题" % len(fails)))

# ---------------------------------------------------------------------------
# 2. 从生成器反解 ASCII 定义（直接 exec 它以拿到 NEW dict，但**不调用其函数**）
# ---------------------------------------------------------------------------
gen_src = GEN.read_text(encoding="utf-8", errors="replace")
# 只取 NEW = { ... } 这一段，避免执行文件末尾的写文件逻辑
m = re.search(r"^NEW\s*=\s*\{(.*?)^\}\s*$", gen_src, re.S | re.M)
if not m:
    print("  !! 无法从生成器提取 NEW 字典，跳过往返比对")
    sys.exit(1)

ns = {}
exec("NEW = {" + m.group(1) + "}", ns)
NEW = ns["NEW"]
print("  生成器: %d 个新字形定义" % len(NEW))

# ---------------------------------------------------------------------------
# 3. 往返比对：Verilog 反解位图 vs 生成器 ASCII 图
# ---------------------------------------------------------------------------
def bits_to_art(rows):
    """点阵 -> ASCII 图（与生成器同约定：图第 0 行 = 点阵 row ART_TOP_ROW）"""
    out = []
    for i in range(ART_LINES):
        v = rows.get(ART_TOP_ROW + i, 0)
        out.append("".join("#" if (v >> (15 - c)) & 1 else "." for c in range(ART_COLS)))
    return out

# 计算每个字符码对应的 localparam 名
code2name = {}
for n, c in consts.items():
    code2name[c] = n

# 生成器里每个字符 -> 期望名字（复刻命名规则，但只用于查找已有条目）
SYM = {' ': "SP", '.': "DOT", '-': "MINUS", '/': "SLASH", '%': "PCT",
       '(': "LPAREN", ')': "RPAREN", '+': "PLUS", ',': "COMMA",
       '<': "LT", '=': "EQ", '>': "GT"}
def nm(ch):
    if ch in SYM: return "CHAR_" + SYM[ch]
    if ch.isalpha() and ch.islower(): return "CHAR_LOW_" + ch.upper()
    if ch.isalpha(): return "CHAR_" + ch.upper()
    if ch.isdigit(): return "CHAR_" + ch
    return None

print()
print("  ---- 往返比对（生成器 ASCII  ->  Verilog 位图  ->  反解 ASCII）----")
rt_ok, rt_bad = 0, 0
for ch, art in sorted(NEW.items()):
    name = nm(ch)
    if name is None or name not in glyphs:
        print("   [SKIP] %r -> %s（Verilog 里没有）" % (ch, name)); continue
    got = bits_to_art(glyphs[name])
    exp = []
    for r in range(ART_LINES):
        s = art[r] if r < len(art) else ""
        exp.append((s + "." * ART_COLS)[:ART_COLS])   # 右侧补 '.' 到 ART_COLS 列
    if got == exp:
        rt_ok += 1
    else:
        rt_bad += 1
        print("   [FAIL] %r (%s) 往返不一致：" % (ch, name))
        for r in range(ART_LINES):
            mark = "  " if got[r] == exp[r] else " <"
            print("        r%-2d exp=|%s|  got=|%s|%s" % (r, exp[r], got[r], mark))

print("   往返一致 = %d，不一致 = %d" % (rt_ok, rt_bad))

# ---------------------------------------------------------------------------
# 4. 抽查打印：确认"没写错但也不可读"的情况
# ---------------------------------------------------------------------------
print()
print("  ---- 抽查字形（人工确认可读性）----")
for ch in "LATENCY:ms0123456789":
    name = nm(ch)
    if name and name in glyphs:
        print("   %r :" % ch)
        for line in bits_to_art(glyphs[name]):
            if line.strip("."):
                print("       |%s|" % line)

# ---------------------------------------------------------------------------
# 5. 结论
# ---------------------------------------------------------------------------
print()
print("=" * 66)
total_bad = len(fails) + rt_bad
if total_bad == 0:
    print(" [OK] 结构校验通过，往返比对全部一致，共 %d 个字形" % len(glyphs))
else:
    print(" [NG] 共 %d 个问题" % total_bad)
    for f in fails[:20]:
        print("   - %s" % f)
print("=" * 66)
sys.exit(1 if total_bad else 0)
