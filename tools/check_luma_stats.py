#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_luma_stats.py --- P6 亮度统计的**独立**数学模型（L2）

为什么需要
----------
`sim/p6/tb_luma_stats.v` 的 uniform 用例用的是**硬编码期望常数**（已经独立于实现），
但那只覆盖 6 个点。本脚本做三件 TB 做不了的事：

  1. **穷举验证系数分解**：`77R = (R<<6)+(R<<3)+(R<<2)+R` 等三条移位加法律，
     对 R/G/B 的全部 0..255 逐一比对（这是"铁律三：常量乘法用移位加法"的
     正确性证明，而不是抽样）。
  2. **与 BT.601 浮点定义交叉核对**：`Y = (77R+150G+29B)>>8` 是 BT.601 的整数
     近似，和浮点式 `Y = 0.299R + 0.587G + 0.114B` 的最大偏差要报出来
     （两种完全不同的算法给出同一个数，才叫"多软件验证"）。
  3. **斜坡图案的整帧期望值**：从图案定义 `v=(3x+5y)&0xFF` 重新累加整帧
     （921600 个像素），与 ModelSim 落盘的 `sum/clip/dark/avg` 逐帧比对。
  4. **平均亮度近似的误差上界**：`avg = ((sum>>10)*18642)>>24` 对全部
     0..255 亮度穷举，报出最大误差（**必须 ≤ 1 LSB**，否则 OSD 上的数字会骗人）。

用法
----
    python tools\\check_luma_stats.py                    # 只做 1/2/4（不需仿真产物）
    python tools\\check_luma_stats.py --ramp _stage/p6_sim/luma_ramp.txt   # 额外做 3
"""
import argparse
import os
import sys

IMG_W, IMG_H = 1280, 720
PIX = IMG_W * IMG_H                    # 921600
BEAT_PER_LINE = IMG_W // 4             # 320
NBEAT = BEAT_PER_LINE * IMG_H          # 230400


# ---------------------------------------------------------------------------
# 1. 系数分解：移位加法 == 常量乘法（穷举 0..255）
# ---------------------------------------------------------------------------
def csd_77(r):
    return (r << 6) + (r << 3) + (r << 2) + r


def csd_150(g):
    return (g << 7) + (g << 4) + (g << 2) + (g << 1)


def csd_29(b):
    return (b << 5) - (b << 2) + b


def check_decomposition():
    print("---- 1. 系数分解（移位加法 == 常量乘法，穷举 0..255）----")
    bad = 0
    for v in range(256):
        if csd_77(v) != 77 * v:
            print("   [NG] 77:  v=%d csd=%d mul=%d" % (v, csd_77(v), 77 * v)); bad += 1
        if csd_150(v) != 150 * v:
            print("   [NG] 150: v=%d csd=%d mul=%d" % (v, csd_150(v), 150 * v)); bad += 1
        if csd_29(v) != 29 * v:
            print("   [NG] 29:  v=%d csd=%d mul=%d" % (v, csd_29(v), 29 * v)); bad += 1
    # 16 位中间量不溢出：max = 255*(77+150+29) 必须 < 65536
    mx = 255 * (csd_77(255) // 255 + 150 + 29)
    print("   移位加法最大值（3 项和）= %d  （16 位上限 65535）%s"
          % (mx, "OK" if mx < 65536 else "!! 溢出"))
    print("   %s" % ("[OK] 三条分解在 0..255 上严格相等（共 768 次比对）"
                     if bad == 0 else "[NG] %d 处不一致" % bad))
    return bad


# ---------------------------------------------------------------------------
# 2. 与 BT.601 浮点定义交叉核对
# ---------------------------------------------------------------------------
def y_int(r, g, b):
    """RTL 里的整数式（CSD 展开后 >>8）"""
    return (csd_77(r) + csd_150(g) + csd_29(b)) >> 8


def y_float(r, g, b):
    """BT.601 浮点定义（完全不同的一套算法）"""
    return 0.299 * r + 0.587 * g + 0.114 * b


def check_bt601():
    print()
    print("---- 2. 整数式 vs BT.601 浮点式（穷举 R=G=B 的灰阶 + 顶点 + 抽样彩色）----")
    worst = 0.0
    worst_at = None
    samples = [(v, v, v) for v in range(256)]
    samples += [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255), (0, 0, 0)]
    for r in range(0, 256, 51):
        for g in range(0, 256, 51):
            for b in range(0, 256, 51):
                samples.append((r, g, b))
    for (r, g, b) in samples:
        d = abs(y_int(r, g, b) - y_float(r, g, b))
        if d > worst:
            worst, worst_at = d, (r, g, b)
    print("   最大偏差 %.3f LSB  出现在 RGB=%s" % (worst, worst_at))
    #   ⚠ 阈值为什么是 1.5 而不是 1.0：
    #     `(77R+150G+29B)>>8` 是 **BT.601 的标准整数近似**，它的偏差有两个来源：
    #       ① 末尾 `>>8` 的截断（floor）：最大 1.0 LSB；
    #       ② 系数舍入：0.299×256=76.544→77(+0.456)、0.587×256=150.27→150(−0.27)、
    #          0.114×256=29.18→29(−0.18)，三者误差之和只有 +0.006，
    #          但**单项**误差最大 0.456 ⇒ 某些颜色上额外贡献约 0.5 LSB。
    #     实测最大 1.313 LSB @ (0,255,102)：Y_int=160、Y_float=161.313。
    #     ⇒ 这是**整数近似的固有误差，不是实现错误**；对 AE 完全够用
    #       （死区是 ±3% ≈ ±3.4 LSB @ 目标 112）。
    #     要压到 1.0 以内就得改成 `(…+128)>>8`，但那会与 `gray_binary_96`
    #     的灰度公式不一致（"AE 看到的亮度"必须等于"灰度模式看到的亮度"），
    #     故**刻意不改**。
    ok = worst <= 1.5
    print("   %s" % ("[OK] 两种算法偏差 <= 1.5 LSB（标准整数近似的固有误差，可接受）"
                     if ok else "[NG] 偏差过大"))
    # 顺带把 TB 里那 6 个硬编码期望值也在这里独立算一遍
    print("   TB uniform 用例的 6 个期望值（本脚本独立复算）：")
    for (r, g, b) in [(128, 128, 128), (255, 255, 255), (0, 0, 0),
                      (255, 0, 0), (0, 255, 0), (0, 0, 255)]:
        print("      (%3d,%3d,%3d) -> int %3d | float %7.3f"
              % (r, g, b, y_int(r, g, b), y_float(r, g, b)))
    return 0 if ok else 1


# ---------------------------------------------------------------------------
# 3. 斜坡图案的整帧期望值（与 ModelSim 落盘比对）
# ---------------------------------------------------------------------------
RAMP_FRAMES = 3


def ramp_frame():
    """从图案定义重新累加整帧。返回 (sum, clip, dark, avg_exact)"""
    s = 0
    clip = 0
    dark = 0
    for y in range(IMG_H):
        base = 5 * y
        for x in range(IMG_W):
            v = (3 * x + base) & 0xFF       # 三通道同值 => Y == v
            s += v
            if v >= 250:
                clip += 1
            if v <= 8:
                dark += 1
    return s, clip, dark, s / PIX


def check_ramp(path):
    print()
    print("---- 3. 斜坡图案整帧期望值（ModelSim 落盘 vs 本脚本重算）----")
    if not os.path.exists(path):
        print("   [SKIP] 找不到 %s（先跑 tb_luma_stats +ramp=1）" % path)
        return 0
    exp = ramp_frame()
    print("   期望: sum=%d clip=%d dark=%d avg_exact=%.4f" % exp)
    bad = 0
    rows = [l.split() for l in open(path, encoding="utf-8").read().split("\n") if l.strip()]
    if len(rows) != RAMP_FRAMES:
        print("   [NG] 落盘帧数 %d 期望 %d" % (len(rows), RAMP_FRAMES)); bad += 1
    for r in rows:
        #  ⚠ 落盘格式已由 5 列改为 **4 列**（去掉了 avg）：平均亮度搬到 ae_ctrl
        #     （24 MHz 域）之后，`luma_stats` 不再输出它 —— 原因是它在 ISP 域
        #     成了该域最差路径（实测 Fmax 77.954 → 60.361 MHz）。
        #     avg 的核对改在 `tb_ae_ctrl` 里做（见该 TB 的 group 2）。
        fno, s, clip, dark = (int(r[0]), int(r[1]), int(r[2]), int(r[3]))
        e_s, e_clip, e_dark, _e_avg = exp
        line_bad = 0
        if s != e_s:
            print("   [NG] frame %d sum=%d 期望 %d" % (fno, s, e_s)); line_bad += 1
        if clip != e_clip:
            print("   [NG] frame %d clip=%d 期望 %d" % (fno, clip, e_clip)); line_bad += 1
        if dark != e_dark:
            print("   [NG] frame %d dark=%d 期望 %d" % (fno, dark, e_dark)); line_bad += 1
        if line_bad == 0:
            print("   [OK] frame %d sum=%d clip=%d dark=%d" % (fno, s, clip, dark))
        bad += line_bad
    return bad


# ---------------------------------------------------------------------------
# 4. 平均亮度近似的误差上界（穷举 0..255）
# ---------------------------------------------------------------------------
AVG_SHIFT = 10
AVG_RECIP = 18642
AVG_RSHIFT = 24


def check_avg():
    print()
    print("---- 4. 平均亮度近似（sum>>10 乘 18642 再 >>24）穷举 0..255 ----")
    worst = 0
    worst_at = None
    for v in range(256):
        s = v * PIX
        approx = (((s >> AVG_SHIFT) * AVG_RECIP) >> AVG_RSHIFT)
        d = abs(approx - v)
        if d > worst:
            worst, worst_at = d, v
        if d > 1:
            print("   [NG] v=%d 近似=%d 偏差 %d" % (v, approx, d))
    print("   最大偏差 %d LSB（出现在 v=%s）" % (worst, worst_at))
    ok = worst <= 1
    print("   %s" % ("[OK] 近似误差 <= 1 LSB，OSD 上的平均亮度可采信" if ok
                     else "[NG] 误差过大，OSD 数字会骗人"))
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ramp", default=r"_stage\p6_sim\luma_ramp.txt")
    a = ap.parse_args()

    print("=" * 70)
    print(" check_luma_stats.py --- P6 亮度统计独立数学模型")
    print("=" * 70)
    bad = 0
    bad += check_decomposition()
    bad += check_bt601()
    bad += check_avg()
    bad += check_ramp(a.ramp)
    print()
    print("=" * 70)
    print(" [OK] 全部独立核对通过" if bad == 0 else " [NG] %d 处不一致" % bad)
    print("=" * 70)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
