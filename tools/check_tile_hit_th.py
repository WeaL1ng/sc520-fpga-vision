# -*- coding: utf-8 -*-
"""独立验证 TILE_HIT_TH 的判别力（"512 能挡零星噪声"这半边的证据）。

为什么单独写一个脚本而不塞进 check_target_detect.py：
  那个文件是"逐帧影像流水"的独立实现；本脚本验证的是**阈值判别力**这一个命题，
  自包含、可单独跑，不干扰既有回归。

命题（三条，必须同时成立才算 512 是对的）：
  P1 实心目标：满铺 tile 的命中数 = 80x80 = 6400 ⇒ TH=12 和 TH=512 **都**合格
     （⇒ 提阈值不会误杀真实目标）
  P2 零星噪声：暗光色度噪声按 1% 密度散布 ⇒ 每 tile ≈ 64 命中
     ⇒ TH=12 **合格（这就是上板照片①的满屏/偏低框）**，TH=512 **不合格** ✅
  P3 判别力：必须能**复现旧行为**（TH=12 下噪声达标），否则说明这个测试
     根本没在检验 512 —— 只验"改了之后还是对"是没有判别力的（P5 §11.6 的教训）
"""
import sys

TILE_PX      = 80
TILE_HIT_THS = [12, 512]          # 旧 / 新
NOISE_PCT    = [0.1, 0.5, 1.0, 2.0, 5.0, 10.0]   # 噪声密度（%），逐个扫

print("=" * 74)
print(" TILE_HIT_TH 判别力独立验证（实心目标 vs 零星噪声）")
print("=" * 74)

ok = True

# ---------------- P1 实心目标 ----------------
print("\n---- P1 实心目标（铺满一个 tile）----")
solid = TILE_PX * TILE_PX
print("     命中数 = %d" % solid)
for th in TILE_HIT_THS:
    r = solid >= th
    print("     TH=%-4d => %s" % (th, "合格 ✅" if r else "不合格 ❌"))
    if not r:
        ok = False
assert solid == 6400
print("     => 两种阈值都合格 ⇒ 提阈值**不误杀真实目标** %s" % ("[OK]" if ok else "[NG]"))

# ---------------- P2/P3 零星噪声 ----------------
print("\n---- P2/P3 零星噪声（噪声密度扫描）----")
print("     密度%%   每 tile 命中   TH=12        TH=512")
band = []
for pct in NOISE_PCT:
    hits = int(round(solid * pct / 100.0))
    q12  = hits >= 12
    q512 = hits >= 512
    band.append((pct, hits, q12, q512))
    print("     %-7.1f %-13d %-11s %s"
          % (pct, hits, "合格(误报!)" if q12 else "挡住", "合格" if q512 else "挡住"))

# P3：存在一个密度区间，TH=12 误报而 TH=512 挡住 —— 这才叫有判别力
witness = [b for b in band if b[2] and not b[3]]
print()
if witness:
    p, h, _, _ = witness[0]
    print("     [OK] P3 判别力成立：密度 %.1f%% 时每 tile %d 命中 ——" % (p, h))
    print("          TH=12 **误报**（复现上板照片①的满屏/偏低框），TH=512 挡住")
else:
    print("     [NG] P3 找不到\"TH=12 误报而 TH=512 挡住\"的密度 ⇒ 本测试没有判别力")
    ok = False

# ---------------- 交叉校验：512 的上界 ----------------
print("\n---- 交叉校验：512 是否过高（会不会把\"物体只盖住 tile 一部分\"也挡掉）----")
for cover in [100, 50, 20, 10, 8, 5]:
    hits = int(round(solid * cover / 100.0))
    print("     物体覆盖 tile %-3d%% => 命中 %-5d  TH=512: %s"
          % (cover, hits, "合格" if hits >= 512 else "挡住"))
print("     => 512 = 覆盖 8%% 即可通过；真实臂章/橙块是整片覆盖 ⇒ 余量充足")
print("     ⚠ 诚实边界：若目标在画面里很小（覆盖 <8%% 的 tile），512 会把它挡掉。")

print("\n" + "=" * 74)
print(" RESULT: %s" % ("PASS  (P1 不误杀 + P2/P3 有判别力)" if ok else "FAIL"))
print("=" * 74)
sys.exit(0 if ok else 1)
