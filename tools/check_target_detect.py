#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check_target_detect.py --- 用 Python **独立核对** target_detect_96 的仿真输出（P5）

为什么
------
本项目已经两次栽在"模块级断言全过、上板才发现错"上（P3 延迟算法、时间基准频率）。
tile 量化 + 阈值 + 增量 min/max 这类逻辑，"有没有框"这种粗检查发现不了
**边界差一个 tile**、**形状判错**、**跨帧没清干净** 这些错。

所以这里**从图案定义出发重新实现一遍算法**（不复用 RTL 任何函数、不抄 RTL 结构），
逐帧比对包围框 / tile 数 / 形状。

独立实现里刻意做了两件事
  ① 色度公式**同时**用整数式（与 RTL 同系数，用于严格比对）
     和浮点标准式（BT.601）算一遍，交叉验证系数没写错；
  ② tile 命中/包围框/形状按**规格**重写，而不是照抄 RTL 的增量写法。

场景（与 tb_target_detect_96.v 的 pix() 一一对应）
  A  橙块    x∈[320,479] y∈[160,319]
  B  蓝块    同几何，蓝色              ⇒ 不应检出
  C  肤色块  同几何，(200,150,120)      ⇒ 不应检出（验证 Cr 阈值排除肤色）
  D  橙长条  x∈[ 80,719] y∈[400,479]   ⇒ 应判 BAR
  E  无目标                             ⇒ valid=0

用法：
    python tools/check_target_detect.py --scene A [--out <target_out.txt>]
"""
import sys
from pathlib import Path

# ---------------------------------------------------------------- 参数（与 RTL 一致）
TILE_PX     = 80
TILE_HIT_TH = 512   # ★ 2026-09-27：12 -> 512
#   原理：真实橙色物体成片（满铺 tile=6400 命中），暗光色度噪声零星（~6 命中）。
#   ⚠ 与 RTL 同步：RTL 的 hit_col 已从 8 位加宽到 13 位
#     （原来饱和在 255，门槛 >255 会永不达标）。
CB_MIN      = 30        # ★ 2026-09-26：新增 Cb 下限（专挡黄色，黄 Cb≈0）
CB_MAX      = 115
CR_MIN      = 146       # ★ 2026-09-26：160 -> 146（哑光橙 Cr 只有 147~152，160 会漏掉）
CR_RATIO_NUM = 49       # ★ 判据③：(Cr-128)/G > NUM/256（对变暗免疫）
# ★ 2026-09-23 新增的"过曝兜底"判据②（必须与 RTL 保持一致，否则本脚本不再是独立实现）
R_CLIP      = 250
RG_MARGIN   = 16
RB_MARGIN   = 24
BAR_RATIO_X2 = 5
IMG_W, IMG_H = 1280, 720

# ---------------------------------------------------------------- 场景定义
BG   = (0x30, 0x30, 0x30)
ORNG = (0xFF, 0x80, 0x00)
BLUE = (0x00, 0x00, 0xFF)
#  ★ 肤色取值修正（2026-09-26）：用户上板实测"手臂不误检" ⇒ 实测肤色 Cr < 146。
#    原来造的 (200,150,120) 的 Cr=155 偏饱和，会得出"肤色被检出"的错误结论。
#    现在用两条：一条贴近实测（应不检出），一条是偏饱和的边界（会检出，如实标注）。
SKIN      = (0xAA, 0x8C, 0x78)   # (170,140,120) Cr=144 < 146 ⇒ 不应检出（贴近实测）
SKIN_SAT  = (0xC8, 0x96, 0x78)   # (200,150,120) Cr=155 ⇒ 偏饱和，**会**被检出（边界）
#  ★ 上板照片定位（2026-09-23）：AE 顶到上限后画面过曝，橙色被洗成 (255,230,200)，
#    此时 Cr 只有 142 < CR_MIN ⇒ 旧判据全画面零命中（板子上就是 `W 00000`）。
#    场景 F 就是复现这个现象；场景 G 是它的反面（白色过曝也必须**不**被检出）。
OVER_ORNG = (255, 230, 200)      # 过曝橙：应 **检出**（新判据②兜底）
OVER_WHT  = (255, 255, 255)      # 过曝白：必须 **不** 检出（R==G==B）
#  ★ 2026-09-26：**哑光橙臂章**（普通室内光下的实测近似值）。
#    上板现象："手机上亮橙照片能认出、普通橙色臂章认不出" —— 就是因为
#    哑光橙的 Cr 只有 152，被旧的 CR_MIN=160 挡掉了。场景 H 专门守这一条。
ARMBAND   = (170, 125, 100)      # 哑光橙臂章（亮）：应 **检出**
DIM_ARM   = ( 85,  62,  50)      # 同一臂章变暗一半：也应 **检出**（判据③守门）
DIM_SKIN  = (140, 105,  84)      # 变暗的肤色：应 **不**检出
YELLOW    = (255, 255,   0)      # 纯黄：必须 **不** 检出（靠 CB_MIN=30 挡，Cr=148 挡不住）

SCENES = {
    "A": [ (320, 160, 479, 319, ORNG) ],
    "B": [ (320, 160, 479, 319, BLUE) ],
    "C": [ (320, 160, 479, 319, SKIN) ],
    "D": [ ( 80, 400, 719, 479, ORNG) ],
    "E": [ ],
    "F": [ (320, 160, 479, 319, OVER_ORNG) ],
    "G": [ (320, 160, 479, 319, OVER_WHT) ],
    "H": [ (320, 160, 479, 319, ARMBAND) ],
    "I": [ (320, 160, 479, 319, YELLOW) ],
    "J": [ (320, 160, 479, 319, DIM_ARM) ],
    "K": [ (320, 160, 479, 319, DIM_SKIN) ],
    "L": [ (320, 160, 479, 319, SKIN_SAT) ],
}

# ---------------------------------------------------------------- 色度：两套独立实现
def cb_cr_int(r, g, b):
    """整数式（与 RTL 同系数、同截断），用于严格比对"""
    cb_raw = (b << 7) + 32768 - (43 * r) - (85 * g)
    cr_raw = (r << 7) + 32768 - (107 * g) - (21 * b)
    return (cb_raw >> 8) & 0xFF, (cr_raw >> 8) & 0xFF

def cb_cr_float(r, g, b):
    """BT.601 浮点标准式，用于交叉验证系数没写错（舍入到整数）"""
    y  = 0.299 * r + 0.587 * g + 0.114 * b
    cb = -0.168736 * r - 0.331264 * g + 0.5 * b + 128.0
    cr =  0.5 * r - 0.418688 * g - 0.081312 * b + 128.0
    return int(round(cb)), int(round(cr)), int(round(y))

def is_warm(r, g, b):
    """★ 两条判据取或 —— 与 RTL 的 warm_pix 完全对应

    判据① YCbCr 矩形阈值：**Cb 有下限和上限**、Cr 有下限。
      ⚠ Cb 下限（CB_MIN）是 2026-09-26 加的关键改动：黄色 Cb≈0、
        橙色 Cb=42~107 ⇒ 用 Cb 下限挡黄色，Cr 门槛才能降到 146 认哑光橙。
    判据② 过曝兜底：R 贴顶 且 R 明显压制 G/B。
      ⚠ 写成 `r - g >= MARGIN` 是**错的**：Python 里 r<g 会得到负数
        （在 Verilog 里会 8 位下溢成大数 ⇒ 比较误判为真），
        两边都会把白/黄放进来。正确写法是 `r >= g + MARGIN`。
    """
    cb, cr = cb_cr_int(r, g, b)
    cb_ok = (cb >= CB_MIN) and (cb <= CB_MAX)
    #  判据(1) 矩形阈值
    by_chroma = cb_ok and (cr >= CR_MIN)
    #  判据(2) 过曝兜底
    by_clip   = (r >= R_CLIP) and (r >= g + RG_MARGIN) and (r >= b + RB_MARGIN)
    #  判据(3)：比值判据 ---- 把亮度除掉 => 对"变暗"免疫
    #     (Cr-128) > (NUM/256)*G   <=>   (cr-128)*256 > NUM*g
    #     RTL 里拿带 32768 偏置的 cr_raw 比较，这里是等价的整数式。
    #  注意：这里**不**加 Cb 绝对门槛 —— Cb-128 同样正比于色差幅度，
    #  变暗时会趋向 128，用绝对门槛会把变暗的橙色误挡（RTL 第一版就栽在这）。
    #  Cr/G 比值本身已排除黄(0.082)/白(0)/灰(0)/蓝(负)。
    by_ratio  = ((cr - 128) * 256 > CR_RATIO_NUM * g)
    return by_chroma or by_clip or by_ratio

def pixel(x, y, rects):
    for (x0, y0, x1, y1, c) in rects:
        if x0 <= x <= x1 and y0 <= y <= y1:
            return c
    return BG

def shape_of(tw, th):
    """与 RTL 同规则，但按规格重写：BAR / BLOCK"""
    if 2 * tw >= BAR_RATIO_X2 * th or 2 * th >= BAR_RATIO_X2 * tw:
        return 1   # BAR
    return 2       # BLOCK

def expected_frame(rects):
    """从图案定义重新算一遍：per-tile 命中 → 合格 tile → 包围框"""
    tile_cols = IMG_W // TILE_PX
    tile_rows = IMG_H // TILE_PX
    hit = [[0] * tile_cols for _ in range(tile_rows)]
    for ty in range(tile_rows):
        for tx in range(tile_cols):
            n = 0
            for y in range(ty * TILE_PX, (ty + 1) * TILE_PX):
                for x in range(tx * TILE_PX, (tx + 1) * TILE_PX):
                    r, g, b = pixel(x, y, rects)
                    if is_warm(r, g, b):
                        n += 1
            hit[ty][tx] = n

    q = [(tx, ty) for ty in range(tile_rows) for tx in range(tile_cols)
         if hit[ty][tx] >= TILE_HIT_TH]
    if not q:
        return dict(valid=0, x_min=0, x_max=0, y_min=0, y_max=0,
                    tile_cnt=0, shape=0, hit=hit)
    xs = [t[0] for t in q]; ys = [t[1] for t in q]
    tx_min, tx_max = min(xs), max(xs)
    ty_min, ty_max = min(ys), max(ys)
    tw, th = tx_max - tx_min + 1, ty_max - ty_min + 1
    return dict(
        valid=1,
        x_min=tx_min * TILE_PX, x_max=tx_max * TILE_PX + TILE_PX - 1,
        y_min=ty_min * TILE_PX, y_max=ty_max * TILE_PX + TILE_PX - 1,
        tile_cnt=len(q), shape=shape_of(tw, th), hit=hit,
        tw=tw, th=th,
    )

# ---------------------------------------------------------------- 主流程
def main():
    scene = "A"
    if "--scene" in sys.argv:
        scene = sys.argv[sys.argv.index("--scene") + 1]
    out = Path(__file__).resolve().parent.parent.joinpath("_stage", "p5_sim", "target_out.txt")
    if "--out" in sys.argv:
        out = Path(sys.argv[sys.argv.index("--out") + 1])

    print("=" * 74)
    print(" target_detect_96 输出独立核对（Python 独立实现，不复用 RTL）")
    print(" 场景 %s   输入 %s" % (scene, out))
    print("=" * 74)

    if scene not in SCENES:
        print("  [NG] 未知场景 %r" % scene); sys.exit(1)
    if not out.exists():
        print("  [NG] 找不到 %s —— 请先跑 tb_target_detect_96" % out); sys.exit(1)

    # ---- 系数交叉验证（整数式 vs BT.601 浮点式）----
    print("  ---- 色度系数交叉验证（整数式 vs BT.601 浮点式）----")
    ref = [("背景", BG), ("橙", ORNG), ("蓝", BLUE), ("肤色", SKIN),
           ("白", (255, 255, 255)), ("黄", (255, 255, 0)), ("红", (255, 0, 0)),
           ("过曝橙", OVER_ORNG), ("过曝白", OVER_WHT)]
    coef_bad = 0
    print("     %-6s %-16s %-16s %-6s %-6s  %s"
          % ("颜色", "整数(Cb,Cr)", "浮点(Cb,Cr)", "整数", "浮点", "判据②(过曝兜底)"))
    for nm, c in ref:
        ci = cb_cr_int(*c); cf = cb_cr_float(*c)[:2]
        wi = is_warm(*c)
        #  浮点式只对应"判据①"，故比较时也只看判据①，避免把两种判据混在一起比
        wf  = (cf[0] <= CB_MAX) and (cf[1] >= CR_MIN)
        wc  = (c[0] >= R_CLIP) and (c[0] >= c[1] + RG_MARGIN) and (c[0] >= c[2] + RB_MARGIN)
        flag = "OK" if wf == ((ci[0] <= CB_MAX) and (ci[1] >= CR_MIN)) else "**不一致**"
        if flag != "OK":
            coef_bad += 1
        print("     %-6s %-16s %-16s %-6s %-6s  %s   %s"
              % (nm, str(ci), str(cf), "暖" if wi else "-", "暖" if wf else "-",
                 ("命中" if wc else "-"), flag))
    if coef_bad:
        print("     [warn] 有 %d 个颜色两式判决不一致（阈值正好卡在边界上）" % coef_bad)

    # ---- 期望值 ----
    exp = expected_frame(SCENES[scene])
    print()
    print("  ---- 期望（Python 独立实现）----")
    if exp["valid"]:
        print("     bbox=(%d,%d)-(%d,%d)  tiles=%d  shape=%d(%s)  tile 尺寸 %dx%d"
              % (exp["x_min"], exp["y_min"], exp["x_max"], exp["y_max"],
                 exp["tile_cnt"], exp["shape"],
                 {1: "BAR", 2: "BLOCK"}.get(exp["shape"], "?"),
                 exp["tw"], exp["th"]))
    else:
        print("     无目标（valid=0）")

    # ---- 实际值 ----
    lines = [l.split() for l in out.read_text().splitlines() if l.strip()]
    print()
    print("  ---- 实测（ModelSim 记录 %d 帧）----" % len(lines))

    fails = []
    if not lines:
        fails.append("一条记录都没有 —— 帧从未结算（先检查 I_tvalid 是否真的在跑）")

    # ⚠ 结算时机 = **本帧帧末**（结构由拍数自计时推出，不依赖 tuser）
    #   ⇒ 每条记录都对应一个完整帧，**没有**"复位后的退化空帧"。
    #   记录格式：8 个数值 + 2 个拼接的十进制串（x 4 位、y 3 位）⇒ 共 10 个 token

    def exp_digits(v, n):
        """期望的十进制位：长度 n 的列表（高位在前）"""
        return [(v // (10 ** (n - 1 - k))) % 10 for k in range(n)]

    for rec in lines:
        if len(rec) != 10:
            fails.append("记录 token 数 %d != 10（8 个数值 + x 4 位串 + y 3 位串）：%r"
                         % (len(rec), rec))
            continue
        fn, v, x0, x1, y0, y1, tc, sh = [int(t) for t in rec[:8]]
        xd = [int(c) for c in rec[8].zfill(4)]     # 千 百 十 个
        yd = [int(c) for c in rec[9].zfill(3)]     # 百 十 个
        got = dict(valid=v, x_min=x0, x_max=x1, y_min=y0, y_max=y1, tile_cnt=tc, shape=sh)
        ok = all(got[k] == exp[k] for k in
                 ("valid", "x_min", "x_max", "y_min", "y_max", "tile_cnt", "shape"))
        # 十进制位独立核对（valid=0 时应全为 0）
        if exp["valid"]:
            ex = exp_digits(exp["x_min"], 4)
            ey = exp_digits(exp["y_min"], 3)
        else:
            ex, ey = [0, 0, 0, 0], [0, 0, 0]
        bcd_ok = (xd == ex) and (yd == ey)
        print("     frame %-3d: valid=%d bbox=(%d,%d)-(%d,%d) tiles=%d shape=%d  BCD x=%s y=%s  %s"
              % (fn, v, x0, y0, x1, y1, tc, sh,
                 "".join(map(str, xd)), "".join(map(str, yd)),
                 "OK" if (ok and bcd_ok) else "**不符**"))
        if not ok:
            diff = [k for k in ("valid", "x_min", "x_max", "y_min", "y_max", "tile_cnt", "shape")
                    if got[k] != exp[k]]
            fails.append("frame %d 不符：%s（实测 %s / 期望 %s）"
                         % (fn, ",".join(diff),
                            {k: got[k] for k in diff}, {k: exp[k] for k in diff}))
        if not bcd_ok:
            fails.append("frame %d 十进制位不符：x=%s(期望%s) y=%s(期望%s)"
                         % (fn, "".join(map(str, xd)), "".join(map(str, ex)),
                            "".join(map(str, yd)), "".join(map(str, ey))))

    # ---- 逐 tile 命中图（便于人工看边界）----
    if exp["valid"]:
        print()
        print("  ---- 期望的 tile 命中图（# = 合格，. = 命中但未达阈值，空格 = 无）----")
        for ty in range(len(exp["hit"])):
            row = ""
            for tx in range(len(exp["hit"][0])):
                n = exp["hit"][ty][tx]
                row += "#" if n >= TILE_HIT_TH else ("." if n else " ")
            print("     ty=%d |%s|" % (ty, row))

    print()
    print("=" * 74)
    if fails:
        print(" [NG] %d 个问题：" % len(fails))
        for f in fails:
            print("   - %s" % f)
    else:
        print(" [OK] 包围框 / tile 数 / 形状 全部与独立实现一致")
    print("=" * 74)
    sys.exit(1 if fails else 0)

if __name__ == "__main__":
    main()
