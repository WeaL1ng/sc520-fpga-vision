#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_cartoon.py --- 用 Python **独立核对** cartoon_96 的仿真输出（P4 多软件验证）

输入：ModelSim 仿真写出的 cartoon_out.txt，每行 "<序号> <96bit hex>"
      每行 = 1 个字 = 4 个像素（px0 在最低 24 位）

★ 关键：本模块沿用 edge_detect_96 的"每拍 2 个采样"结构
   pair0 = (Y0+Y1)>>1,  pair1 = (Y2+Y3)>>1
   ⇒ 每拍算 2 个梯度，各自作用于**一对**像素：
        (p0,p1) 用 grad0      (p2,p3) 用 grad1
   核对时必须按**像素对**判定，不能按单像素。

独立实现的期望模型（**不复用 RTL 的任何函数**）
------------------------------------------------
  Y    = (77R + 150G + 29B) >> 8          # 灰度
  Q    = (V & 0xF0) | 0x08                 # 16 级量化
  grad = max(3x3) - min(3x3)               # 形态学梯度（在 pair 采样域上）
  out  = (grad > TH) ? 黑 : {Qr,Qg,Qb}

测试图案（tb_cartoon_96.v）
---------------------------
  x <  640 : 暗灰 (0x60)   x >= 640 : 亮灰 (0xC0)
  每对像素 = (2k, 2k+1) ⇒ 边缘落在 pair 319 (x=638,639) 与 pair 320 (x=640,641) 之间

判定
----
  1. 平坦区（远离边缘）必须 == 量化色
  2. 边缘 pair 上必须出现黑像素
  3. 颜色集合只应含 {量化暗, 量化亮, 黑}
  4. 黑像素总数必须**远小于**平坦像素数（防止"字边界假边缘"复发）
"""
import sys
from pathlib import Path

# 用法： python check_cartoon.py [--out <cartoon_out.txt 的路径>]
OUT = Path(__file__).resolve().parent.parent.joinpath("_stage", "p4_sim", "cartoon_out.txt")
if "--out" in sys.argv:
    OUT = Path(sys.argv[sys.argv.index("--out") + 1])
TH  = 20
QUANT_BITS = 3      # 与 cartoon_96.v 默认一致（3 ⇒ 每通道 8 级）
IMG_W = 1280

def lum(r, g, b):  return (77*r + 150*g + 29*b) >> 8

def q(v):
    """★ 2026-09-21 改：与 RTL 的新量化一致 —— 取高 QUANT_BITS 位后**复制填满** 8 位。
    旧写法 (v & 0xF0) | 0x08 只有 16 级、相邻差 16，肉眼几乎看不出量化 ⇒ 不像卡通。"""
    if QUANT_BITS == 1:
        return 0xFF if ((v >> 7) & 1) else 0x00
    if QUANT_BITS == 2:
        h = (v >> 6) & 0x3
        return (h << 6) | (h << 4) | (h << 2) | h
    if QUANT_BITS == 3:
        # 严格复现 RTL 的 {v[7:5], v[7:5], v[7:6]}
        a = (v >> 5) & 0x7
        b2 = (v >> 6) & 0x3
        return (a << 5) | (a << 2) | b2
    return (v & 0xF0) | ((v >> 4) & 0x0F)

print("=" * 70)
print(" cartoon_96 输出独立核对（Python，期望模型独立实现）")
print(" 输入文件：%s" % OUT)
print("=" * 70)

if not OUT.exists():
    print("  [NG] 找不到 %s —— 请先跑 tb_cartoon_96" % OUT)
    sys.exit(1)

lines = [l.split() for l in OUT.read_text().splitlines() if l.strip()]
NW = len(lines)
print("  读入 %d 个字（= %d 像素，约 %d 行）" % (NW, NW*4, NW*4//IMG_W))

Y_D, Y_B = lum(0x60,0x60,0x60), lum(0xC0,0xC0,0xC0)
Q_D, Q_B = q(Y_D), q(Y_B)
print("  暗灰 0x60 -> Y=%d -> Q=%d(0x%02X)" % (Y_D, Q_D, Q_D))
print("  亮灰 0xC0 -> Y=%d -> Q=%d(0x%02X)" % (Y_B, Q_B, Q_B))
print("  边缘梯度 = %d  阈值 %d" % (Y_B - Y_D, TH))
print("  ⚠ 本模块每拍 2 个采样 ⇒ 判别按**像素对**（pair = 相邻 2 像素）")
print()

colors = {}
flat_ok = flat_bad = 0
edge_pairs = 0
black_in_edge_pair = 0
black_outside_edge = 0
bad_ex = []
black_xs = set()      # ★ 回归守门：所有黑像素的 x 坐标集合
black_rows = set()

for wi, (idx, hv) in enumerate(lines):
    v = int(hv, 16)
    row = wi // (IMG_W // 4)          # 第几个输出行
    for k in range(4):
        px = (v >> (24*k)) & 0xFFFFFF
        r, g, b = (px>>16)&0xFF, (px>>8)&0xFF, px&0xFF
        x = (wi*4 + k) % IMG_W
        pair = x // 2                  # 像素对序号 0..639
        c = (r, g, b)
        colors[c] = colors.get(c, 0) + 1

        if c == (0,0,0):
            black_xs.add(x)
            black_rows.add(row)
            # 边缘应出现在 pair 319/320 附近
            if 318 <= pair <= 321:
                black_in_edge_pair += 1
            else:
                black_outside_edge += 1
                if len(bad_ex) < 6:
                    bad_ex.append(("边缘外的黑像素", row, x, pair))
        else:
            want = (Q_D,)*3 if x < 640 else (Q_B,)*3
            if c == want: flat_ok += 1
            else:
                flat_bad += 1
                if len(bad_ex) < 8:
                    bad_ex.append(("平坦区量化不符", row, x, c, want))

print("  ---- 颜色直方图 ----")
for c, n in sorted(colors.items(), key=lambda kv: -kv[1])[:6]:
    print("    RGB(%3d,%3d,%3d)  x%-6d" % (c[0], c[1], c[2], n))

print()
print("  ---- 判定 ----")
print("    平坦区符合 %-7d 不符 %-7d" % (flat_ok, flat_bad))
print("    边缘处黑像素 %-5d   边缘外黑像素 %-5d" % (black_in_edge_pair, black_outside_edge))
print("    黑像素 x 集合 = %s" % (sorted(black_xs) if black_xs else "空"))
print("    出现黑像素的行 = %s" % (sorted(black_rows) if black_rows else "无"))

fails = []
if flat_ok == 0:
    fails.append("平坦区一个都没通过（模型可能不匹配）")
if flat_bad > 0:
    fails.append("平坦区有 %d 像素未按量化输出" % flat_bad)
if black_in_edge_pair == 0:
    fails.append("边缘处未出现黑像素（黑像素 x=%s）—— 边缘检测失效或整体错位"
                 % (sorted(black_xs) if black_xs else "空"))

# ★★ 回归守门（对应 2026-09-21 修的那个 bug）
#   加了 p1 流水级后只延迟了"数据"没延迟"控制" ⇒ 输出整体右移 4 像素，
#   真实竖边从 x=640 跑到 x=644。这个断言把"错位"和"边缘失效"区分开。
EXPECT_BLACK_X = {640, 641, 642, 643}
if black_xs and black_xs != EXPECT_BLACK_X:
    fails.append("★ 边缘黑像素位置 %s ≠ %s —— 输出存在整体错位（数据/控制延迟不等）"
                 % (sorted(black_xs), sorted(EXPECT_BLACK_X)))

allowed = {(Q_D,)*3, (Q_B,)*3, (0,0,0)}
extra = {c for c in colors if c not in allowed}
if extra:
    fails.append("存在 %d 种期望外的颜色：%s" % (len(extra), list(extra)[:4]))

# ★ 关键回归项：假边缘不得复发
false_edge = black_outside_edge
total_black = black_in_edge_pair + black_outside_edge
if total_black > 0 and false_edge > total_black * 0.5:
    fails.append("黑像素多数在边缘之外（%d/%d）—— 假边缘复发！" % (false_edge, total_black))
if false_edge > 200:
    fails.append("边缘外黑像素多达 %d，疑似存在系统性假边缘" % false_edge)

# 信息项（不算失败）：图像最上面 2 行没有 y−1/y−2 行，3x3 窗口不可用
#   ⇒ 按设计不判边（窗口有效位屏蔽），只输出量化色。整机 720 行里 2 行，不可见。
if black_rows and min(black_rows) >= 2:
    print("    [info] 黑像素自第 %d 行开始（前 2 行窗口不可用 ⇒ 按设计不判边）"
          % min(black_rows))

if bad_ex:
    print()
    print("  ---- 偏差样例 ----")
    for e in bad_ex[:6]:
        print("    %s" % (e,))

print()
print("=" * 70)
if fails:
    print(" [NG] %d 个问题：" % len(fails))
    for f in fails:
        print("   - %s" % f)
else:
    print(" [OK] 量化正确、真边缘变黑、无系统性假边缘 —— 卡通化行为符合模型")
print("=" * 70)
sys.exit(1 if fails else 0)
