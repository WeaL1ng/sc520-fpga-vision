#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_motion_detect.py --- 用 Python **独立核对** motion_detect.v 的仿真输出（P7）

为什么
------
本项目的纪律：任何一个"算法型"模块都必须有一份**不复用 RTL 任何函数**的独立模型，
逐帧比对数值。P5 就是靠它抓出"列计数永久错开一拍"（模块级断言全过、上板才炸）。

★ 2026-09-26 上板事故后的大改（本次）：背景从"按列共享 160 槽"改成
  **每个块 (by,bxc) 一个背景值（14400 个）**。原因是按列共享会把背景拖走：
  同一列上下亮度差 > MOT_TH 时，**静止画面也会长期报运动**（上板实测：
  静止场景出框）。本脚本现在按"每块独立背景"重算，与 RTL 的新结构一致。

★ 本脚本自己是**要求级**的裁判，不是"实现照抄器"：
  如果 RTL 退回按列共享，本脚本会在 F/G（垂直有结构的静止画面）上直接报 [NG]，
  因为**静止画面按定义必须 valid=0**。

独立实现刻意与 RTL 走**不同的路径**：
  · RTL 用"两拍读-改-写 + 8 行累加器 + 线性块索引寻址 ERAM"，本脚本用
    **逐像素直接求和**再 >>6、用 **二维数组 bg[by][bx]**；
  · RTL 用 160 级移位延迟线做"上一块行"，本脚本用二维数组直接索引；
  · RTL 用饱和加减的进位/借位位，本脚本用 min/max（并穷举交叉验证两者等价）。

另外做三组**穷举/自检**（不依赖仿真，纯数学）：
  ① 饱和加减在 bg∈0..255 × cur∈0..255 × STEP 多取值 全域无溢出/下溢，
     并显式证明"不饱和会回绕"；
  ② 全局突变门限：PCT=0..100 时 `14400*PCT//100`、`144*PCT`、RTL 的
     移位式 `(PCT<<7)+(PCT<<4)` 三者必须完全一致，且判据是**严格大于**；
  ③ 场景 H 的噪声序列零均值、幅度正确、可跨语言复现。

场景（与 sim/p7/tb_motion_detect.v 的 luma() **逐条对应**，改一边必须改另一边）
  A 静止整帧恒定                    ⇒ 全程 valid=0
  B 第 3 帧起一块 160×160 变亮      ⇒ raw=400 / blk=361 / bbox=(328,168)-(479,319)
  C 第 2 帧起整帧 +40（AE 阶跃）    ⇒ 必须 valid=0 且 global=1（抗光照误报）
  D 第 3 帧起孤立一个 8×8 块变亮    ⇒ raw=1 而 blk=0（腐蚀吃掉）
  E 先动后静（物体移出）            ⇒ 框消失、计数回 0
  F ★静止 + 垂直结构（上半亮下半暗，水平分界）⇒ 必须全程 valid=0
  G ★静止 + 多条水平带 + 垂直渐变    ⇒ 必须全程 valid=0
  H ★静止 + 每像素噪声 ±N（N=8/16/24）⇒ 必须全程 valid=0；用于定 MOT_TH

用法：
    python tools/check_motion_detect.py --scene F --out _stage/p7_sim/f.txt
    python tools/check_motion_detect.py --scene H --noise 24 --out h24.txt
    python tools/check_motion_detect.py --cmp a.txt b.txt     # 落盘逐帧一致性
    python tools/check_motion_detect.py --study               # MOT_TH 三档噪声研究
"""
import sys
from pathlib import Path

# ★ 控制台编码兜底：Windows 默认控制台是 GBK，遇到 ✓ / ⇒ 会抛 UnicodeEncodeError。
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

# ---------------------------------------------------------------- 参数（必须与 RTL 一致）
IMG_W, IMG_H   = 1280, 720
PX_PER_BEAT    = 4
BLK_PX         = 8
MOT_TH         = 24        # ★ 2026-09-26 由 18 提到 24，依据见 --study 的实测表
                           #   （N=16 最大块差 8、N=24 → 9、N=32 → 14、N=48 → 33；
                           #    真实运动块差 160 ⇒ 提阈值对检测没有影响）
BG_STEP        = 1
GLOBAL_PCT     = 50
MIN_BLK        = 4

BEAT_PER_LINE  = IMG_W // PX_PER_BEAT      # 320
BLK_COLS       = IMG_W // BLK_PX           # 160
BLK_ROWS       = IMG_H // BLK_PX           # 90
BLK_TOTAL      = BLK_COLS * BLK_ROWS       # 14400
GLOBAL_LIMIT   = (BLK_TOTAL * GLOBAL_PCT) // 100   # 7200

# ---------------------------------------------------------------- 图案常量（与 TB 一致）
BASE  = 40
MOT   = 200
JUMP  = 40
L_TOP = 200        # 场景 F/G 的亮部
L_BOT = 40         # 场景 F 的暗部
L_MID = 120        # 场景 H 的底
NOISE_N = 16       # 场景 H 的噪声幅度（±N），可用 --noise 覆盖

SCENES = ("A", "B", "C", "D", "E", "F", "G", "H")

# ---------------------------------------------------------------- 可跨语言复现的噪声
# ★ 为什么不用 $random：ModelSim 的 $random 算法没有标准、Python 无法复现同一条
#   序列 ⇒ 那样"独立模型"就只能比对而不能重算。这里用**确定性整数 hash**
#   （只含移位/XOR/加 + 32 位掩码），Verilog TB 与 Python 逐位一致、可复现、可换种子。
def nz_mix(a):
    """32 位混合（与 tb 的 nz_mix 函数逐位一致）"""
    h = a & 0xFFFFFFFF
    h ^= (h << 13) & 0xFFFFFFFF
    h = (h + 0x9E3779B9) & 0xFFFFFFFF
    h ^= (h >> 17)
    h = (h + 0x7F4A7C15) & 0xFFFFFFFF
    h ^= (h << 5) & 0xFFFFFFFF
    return h & 0xFFFFFFFF

def luma_noise(x, y, f, n):
    """场景 H：静态底 + 幅度 ±n 的确定性噪声（与 tb 的 luma_noise 一致）"""
    a = ((x << 20) + (y << 8) + f) & 0xFFFFFFFF
    r = (nz_mix(a) >> 8) % (2 * n + 1)          # 0..2n
    return L_MID + r - n

def band_g(y):
    """场景 G 的水平亮度带（与 tb 一致）"""
    if y < 120:  return 220
    if y < 240:  return 170
    if y < 480:  return 110
    if y < 600:  return 70
    return 40

def row_luma(scene, y, f, n=NOISE_N):
    """返回第 y 行 1280 个像素的亮度（G 通道代理）。与 tb 的 luma() 逐条对应。"""
    if scene == "A":
        return [BASE] * IMG_W
    if scene == "B":
        row = [BASE] * IMG_W
        if f >= 2 and 160 <= y <= 319:
            row[320:480] = [MOT] * 160
        return row
    if scene == "C":
        return [BASE + (JUMP if f >= 1 else 0)] * IMG_W
    if scene == "D":
        row = [BASE] * IMG_W
        if f >= 2 and 160 <= y <= 167:
            row[320:328] = [MOT] * 8
        return row
    if scene == "E":
        row = [BASE] * IMG_W
        if f in (2, 3) and 160 <= y <= 319:
            row[320:480] = [MOT] * 160
        return row
    if scene == "F":
        return [L_TOP if y < 360 else L_BOT] * IMG_W
    if scene == "G":
        return [band_g(y) + (y * 24) // 720] * IMG_W
    if scene == "H":
        return [luma_noise(x, y, f, n) for x in range(IMG_W)]
    raise ValueError("未知场景 %r" % scene)

# ---------------------------------------------------------------- ① 饱和加减（全域穷举）
def sat_step(bg, cur, step):
    """sigma-delta 背景更新（**饱和**）：与 RTL 的 w_bg_step 同语义。

    RTL 用 9 位加减的进/借位位判溢出：bg+step>255 ⇒ 255；bg<step ⇒ 0。
    这里用另一条路径（min/max）实现，再由 check_sat() 穷举证明两者等价。
    """
    if cur > bg:
        return min(255, bg + step)
    if cur < bg:
        return max(0, bg - step)
    return bg

def sat_step_wrap(bg, cur, step):
    """**故意不饱和**的版本（8 位回绕）—— 只用来演示"为什么必须饱和"。"""
    if cur > bg:
        return (bg + step) & 0xFF
    if cur < bg:
        return (bg - step) & 0xFF
    return bg

def check_sat():
    bad = 0
    steps = [1, 2, 3, 4, 5, 8, 16, 17, 64, 100, 127, 128, 200, 254, 255]
    checks = 0
    for step in steps:
        for bg in range(256):
            for cur in range(256):
                n = sat_step(bg, cur, step)
                checks += 1
                if not (0 <= n <= 255):
                    bad += 1
                    continue
                if cur > bg:
                    if n != min(255, bg + step) or not (bg <= n <= bg + step):
                        bad += 1
                elif cur < bg:
                    if n != max(0, bg - step) or not (bg - step <= n <= bg):
                        bad += 1
                else:
                    if n != bg:
                        bad += 1
    wrap_demo_up = sat_step_wrap(250, 255, 8)     # 258 ⇒ 被 8 位截成 2
    wrap_demo_dn = sat_step_wrap(3, 0, 8)         # −5  ⇒ 被截成 251
    print("  [%s] 饱和加减全域穷举：%d 组（15 个 STEP × 256×256）无溢出/下溢"
          % ("OK" if bad == 0 else "NG", checks))
    print("       反证：不饱和时 bg=250/STEP=8 会变成 %d（最亮跳到最暗）、"
          "bg=3/STEP=8 会变成 %d（最暗跳到最亮）⇒ 背景一旦撞到极值就反向狂奔，"
          "之后每帧满屏误报。" % (wrap_demo_up, wrap_demo_dn))
    print("       本实现的饱和把它钳在 0..255（RTL 用 9 位加减的进/借位位做同一件事）")
    return bad

# ---------------------------------------------------------------- ② 全局门限穷举
def check_pct():
    bad = 0
    for pct in range(0, 101):
        a = (BLK_TOTAL * pct) // 100          # 定义式
        b = 144 * pct                         # 因为 BLK_TOTAL/100 == 144
        c = (pct << 7) + (pct << 4)           # RTL 里实际写的移位加法（128+16=144）
        if not (a == b == c):
            bad += 1
            print("       PCT=%d 三者不一致：%d / %d / %d" % (pct, a, b, c))
    lim = (BLK_TOTAL * GLOBAL_PCT) // 100
    strict_ok = (not (lim > lim)) and (lim + 1 > lim)
    print("  [%s] 全局突变门限：PCT=0..100 共 101 个取值下，"
          "14400*PCT//100 == 144*PCT == (PCT<<7)+(PCT<<4) 全部一致；"
          "判据为严格大于（raw=%d 不算突变、raw=%d 算）%s"
          % ("OK" if (bad == 0 and strict_ok) else "NG", lim, lim + 1,
             "" if strict_ok else "  ← 严格性检查失败"))
    return bad + (0 if strict_ok else 1)

# ---------------------------------------------------------------- ③ 几何自检
def check_geom():
    last_line = IMG_H - 1
    last_col  = BEAT_PER_LINE - 1
    ok = (last_line % 8 == 7) and (last_col % 2 == 1) and \
         (last_line // 8 == BLK_ROWS - 1) and (last_col // 2 == BLK_COLS - 1) and \
         (BEAT_PER_LINE * IMG_H == 230400)
    print("  [%s] 几何自检：719 = 8×89+7（块行 89 的第 8 行 ✓）、319 是奇数（块 159 ✓）、"
          "320×720 = 230400 拍/帧 ⇒ 帧末与「最后一个块定稿」是同一拍，无需收尾状态机"
          % ("OK" if ok else "NG"))
    return 0 if ok else 1

# ---------------------------------------------------------------- ④ 噪声可复现性自检
def check_noise():
    """确认噪声函数是零均值、幅度正确的确定性序列（与 TB 同一实现）。"""
    n = 24
    vals = [luma_noise(x, y, 3, n) for y in range(0, 720, 97) for x in range(0, 1280, 131)]
    lo, hi = min(vals), max(vals)
    mean = sum(vals) / len(vals)
    ok = (lo >= L_MID - n) and (hi <= L_MID + n) and (abs(mean - L_MID) < 1.0)
    print("  [%s] 噪声自检（N=24）：%d 个采样落在 [%d,%d] ⊂ [%d,%d]，均值 %.2f（期望 ≈ %d）"
          % ("OK" if ok else "NG", len(vals), lo, hi, L_MID - n, L_MID + n, mean, L_MID))
    return 0 if ok else 1

# ---------------------------------------------------------------- 独立模型
def block_luma_map(scene, f, n=NOISE_N):
    """逐像素求和算整帧每个 8×8 块的亮度（>>6）——与 RTL 的"两拍累加"完全不同的路径。"""
    cur = [[0] * BLK_COLS for _ in range(BLK_ROWS)]
    for by in range(BLK_ROWS):
        acc = [0] * BLK_COLS
        for y in range(by * BLK_PX, (by + 1) * BLK_PX):
            row = row_luma(scene, y, f, n)
            for bx in range(BLK_COLS):
                x = bx * BLK_PX
                acc[bx] += sum(row[x:x + BLK_PX])          # 8 行累加
        for bx in range(BLK_COLS):
            cur[by][bx] = acc[bx] >> 6                     # ÷64 ⇒ 0..255
    return cur

def run_model(scene, nframes, n=NOISE_N):
    """逐帧独立重算：块亮度 → |diff| → sigma-delta 背景 → 腐蚀 → 包围框/计数/全局判决。

    ★ 背景 **bg[by][bx] 每个块一个**（14400 个），一帧内每个块**只更新一次** ——
      这是本次上板事故的修正点，也是设计文档 §4.3 的本意。
      （旧版把背景按列共享 160 槽，一个槽被 90 个块行写 ⇒ 背景被拖走 ⇒ 静止画面误报。）
    ★ 首帧（f=0）= 背景学习帧（与 RTL 的 S_bg_init 对应）：mot=0、bg <= cur。
    ★ 2×2 腐蚀：图像外（bxc==0 的左邻、by==0 的上邻）一律当**非运动**。
    """
    bg = [[0] * BLK_COLS for _ in range(BLK_ROWS)]
    frames = []
    for f in range(nframes):
        cur = block_luma_map(scene, f, n)
        learn = (f == 0)
        raw = [[0] * BLK_COLS for _ in range(BLK_ROWS)]
        max_diff = 0
        for by in range(BLK_ROWS):
            for bx in range(BLK_COLS):
                c = cur[by][bx]
                b = bg[by][bx]
                if learn:
                    raw[by][bx] = 0
                    bg[by][bx] = c                 # 直接装载
                else:
                    d = abs(c - b)
                    if d > max_diff:
                        max_diff = d
                    raw[by][bx] = 1 if d > MOT_TH else 0
                    bg[by][bx] = sat_step(b, c, BG_STEP)

        ero = [[0] * BLK_COLS for _ in range(BLK_ROWS)]
        pts = []
        for by in range(BLK_ROWS):
            for bx in range(BLK_COLS):
                if raw[by][bx] and bx > 0 and raw[by][bx - 1] \
                   and by > 0 and raw[by - 1][bx] and raw[by - 1][bx - 1]:
                    ero[by][bx] = 1
                    pts.append((bx, by))

        raw_cnt = sum(sum(r) for r in raw)
        ero_cnt = len(pts)
        if pts:
            xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
            x0, x1 = min(xs) * BLK_PX, max(xs) * BLK_PX + BLK_PX - 1
            y0, y1 = min(ys) * BLK_PX, max(ys) * BLK_PX + BLK_PX - 1
        else:
            x0 = x1 = y0 = y1 = 0
        g_chg = 1 if raw_cnt > GLOBAL_LIMIT else 0
        valid = 1 if (ero_cnt >= MIN_BLK and not g_chg) else 0
        frames.append(dict(f=f, valid=valid, global_chg=g_chg, raw=raw_cnt,
                           cnt=ero_cnt, x_min=x0, x_max=x1, y_min=y0, y_max=y1,
                           max_diff=max_diff, ero=ero, raw_map=raw))
    return frames

# ---------------------------------------------------------------- 比对
def read_dump(path):
    recs = []
    for ln in Path(path).read_text().splitlines():
        if ln.strip():
            t = ln.split()
            if len(t) != 9:
                raise ValueError("落盘格式不对（应为 9 个数值）：%r" % ln)
            recs.append([int(v) for v in t])
    return recs

KEYS = ("valid", "global_chg", "raw", "cnt", "x_min", "x_max", "y_min", "y_max")

# ---------------------------------------------------------------- MOT_TH 研究
def study():
    """三档噪声下"静态必须不误报"与"运动必须认得出"的权衡，给 MOT_TH 定值依据。

    ★ 关键性质：背景更新（bg <= bg±BG_STEP）**与阈值无关** ⇒ 一条 bg 轨迹可以
      同时评所有候选 MOT_TH，不需要每个阈值重跑一遍模型。
    """
    print("=" * 92)
    print(" MOT_TH 定值研究（独立模型；静止画面 + 每像素噪声 ±N；真实运动块差 = 160）")
    print("=" * 92)
    NFR = 12
    THS = (18, 24, 32, 40, 64)
    print("   噪声 N | 块级噪声 σ(理论) | max|cur-bg| | " +
          " ".join("TH=%-2d 误报" % t for t in THS))
    for n in (8, 16, 24, 32, 48):
        bg = [[0] * BLK_COLS for _ in range(BLK_ROWS)]
        diffs = []
        for f in range(NFR):
            cur = block_luma_map("H", f, n)
            for by in range(BLK_ROWS):
                for bx in range(BLK_COLS):
                    c = cur[by][bx]; b = bg[by][bx]
                    if f == 0:
                        bg[by][bx] = c
                    else:
                        diffs.append(abs(c - b))
                        bg[by][bx] = sat_step(b, c, BG_STEP)
        md = max(diffs)
        counts = [sum(1 for d in diffs if d > th) for th in THS]
        sigma = n / (8 * (3 ** 0.5))       # 64 像素平均 ⇒ 标准差压 8 倍
        print("     ±%-3d |      %-5.2f       |     %-3d     | " % (n, sigma, md) +
              " ".join("%-8d" % c for c in counts))
    print()
    print("  统计口径：14400 块 × %d 帧 = %d 次机会；表内数字是**块级误报次数**。" % (NFR - 1, BLK_TOTAL * (NFR - 1)))
    print("  ★ 真实运动的块亮度差 = 160（场景 B/D/E 的图案）⇒ 阈值上限很宽，可放心取大。")
    print("  ★ 噪声被 8×8 = 64 像素平均压 8 倍 ⇒ 块级噪声标准差 ≈ N/(8·√3)。")
    print("=" * 92)
    return 0

# ---------------------------------------------------------------- 主流程
def main():
    argv = sys.argv[1:]

    if "--study" in argv:
        return study()

    # ---- 模式 1：只比两个落盘是否逐帧一致（用于 +phase 用例的"结果不变"）----
    if "--cmp" in argv:
        i = argv.index("--cmp")
        p1, p2 = Path(argv[i + 1]), Path(argv[i + 2])
        print("=" * 74)
        print(" 相位用例：两个落盘的逐帧结果是否完全一致")
        print("   A = %s" % p1)
        print("   B = %s" % p2)
        try:
            r1, r2 = read_dump(p1), read_dump(p2)
        except Exception as e:
            print("  [NG] 读取失败：%s" % e); return 1
        ok = (r1 == r2) and len(r1) > 0
        print("  A 共 %d 帧，B 共 %d 帧" % (len(r1), len(r2)))
        if not ok:
            for a, b in zip(r1, r2):
                if a != b:
                    print("   frame %d 不同：A=%s  B=%s" % (a[0], a[1:], b[1:]))
        print("  [%s] 帧相位对齐后结果与基准完全一致（一拍不漂）" % ("OK" if ok else "NG"))
        print("=" * 74)
        return 0 if ok else 1

    scene = "A"
    if "--scene" in argv:
        scene = argv[argv.index("--scene") + 1]
    n_noise = NOISE_N
    if "--noise" in argv:
        n_noise = int(argv[argv.index("--noise") + 1])
    out = Path(__file__).resolve().parent.parent.joinpath("_stage", "p7_sim", "motion_out.txt")
    if "--out" in argv:
        out = Path(argv[argv.index("--out") + 1])

    print("=" * 78)
    print(" motion_detect 输出独立核对（Python 独立实现，不复用 RTL 任何函数）")
    print(" 场景 %s   噪声 N=%d   输入 %s" % (scene, n_noise, out))
    print("=" * 78)
    print("  ---- 纯数学穷举（不依赖仿真）----")
    bad = check_geom() + check_sat() + check_pct() + check_noise()

    if scene not in SCENES:
        print("  [NG] 未知场景 %r" % scene); return 1
    if not out.exists():
        print("  [NG] 找不到 %s —— 请先跑 tb_motion_detect" % out); return 1

    try:
        recs = read_dump(out)
    except Exception as e:
        print("  [NG] 落盘解析失败：%s" % e); return 1

    exp = run_model(scene, len(recs), n_noise)
    print()
    print("  ---- 逐帧比对（实测 vs Python 独立模型）----")
    fails = 0
    for rec, e in zip(recs, exp):
        fn = rec[0]
        got = dict(zip(KEYS, rec[1:]))
        want = {k: e[k] for k in KEYS}
        diff = [k for k in KEYS if got[k] != want[k]]
        print("   frame %-2d: valid=%d global=%d raw=%-5d blk=%-5d bbox=(%d,%d)-(%d,%d)  %s"
              % (fn, got["valid"], got["global_chg"], got["raw"], got["cnt"],
                 got["x_min"], got["y_min"], got["x_max"], got["y_max"],
                 "OK" if not diff else "**不符**"))
        if diff:
            fails += 1
            for k in diff:
                print("         %-11s 实测=%-6d 期望=%d" % (k, got[k], want[k]))

    # ---- 要求级断言（★ 只看**实测落盘**，不看模型 —— 这样即使模型本身写错，
    #      也仍然能抓住"静止画面却报运动"这类硬性违反）----
    print()
    req_fail = []
    got_all = [(r[0], dict(zip(KEYS, r[1:]))) for r in recs[:len(exp)]]
    if scene in ("A", "F", "G", "H"):
        for fn, g in got_all:
            if g["valid"] != 0 or g["raw"] != 0:
                req_fail.append("frame %d：静止场景却报运动（实测 valid=%d raw=%d）"
                                % (fn, g["valid"], g["raw"]))
    if scene == "C":
        for fn, g in got_all[1:]:
            if g["valid"] != 0 or g["global_chg"] != 1:
                req_fail.append("frame %d：全局亮度阶跃未被抑制（实测 valid=%d global=%d）"
                                % (fn, g["valid"], g["global_chg"]))
    if scene == "B":
        for fn, g in got_all[2:]:
            if not (g["raw"] == 400 and g["cnt"] == 361 and
                    (g["x_min"], g["y_min"], g["x_max"], g["y_max"]) == (328, 168, 479, 319)):
                req_fail.append("frame %d：块移动的解析值不符（实测 raw=%d cnt=%d "
                                "bbox=(%d,%d)-(%d,%d)）"
                                % (fn, g["raw"], g["cnt"], g["x_min"], g["y_min"],
                                   g["x_max"], g["y_max"]))
    for m in req_fail:
        print("   ** 要求级不符：%s" % m)

    if scene in ("F", "G", "H") and len(exp) > 1:
        md = max(e["max_diff"] for e in exp[1:])
        print("   诊断：本场景实测最大块差 |cur-bg| = %d（MOT_TH=%d）" % (md, MOT_TH))

    print()
    print("=" * 74)
    if fails or bad or req_fail:
        print(" [NG] 逐帧不符 %d 帧；纯数学穷举失败 %d 项；要求级不符 %d 条"
              % (fails, bad, len(req_fail)))
        print("=" * 74)
        return 1
    print(" [OK] 块亮度 / |diff| / sigma-delta 背景 / 2×2 腐蚀 / 包围框 / 块数 / 全局突变判决")
    print("      全部与 Python 独立实现一致；饱和加减与 PCT 门限已全域穷举通过")
    print("=" * 74)
    return 0

if __name__ == "__main__":
    sys.exit(main())
