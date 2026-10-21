#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_osd_layout.py --- OSD 各区**屏幕矩形互不重叠**的独立校验（P3 多软件验证）

为什么需要
----------
P3 新增了 `LATENCY: ### ms` 文本区。若它与既有元素（Logo / 安路 CNT / 模式数字 /
底部状态条）在屏幕上重叠，会出现互相覆盖 —— 这在仿真里不易察觉（都是"有像素"），
但上板一眼就能看出。

做法（独立于 RTL 的第二种实现）
------------------------------
**直接从 `hdmi_mixer.v` 正则抽取各区的位置常量**，算出每个区的屏幕矩形，
两两求交，报告重叠。

注意：只抽 `localparam`，不解释任何 RTL 逻辑，因此与 RTL 实现相互独立。
"""
import re
import sys
from itertools import combinations
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent
MIX = (BASE / r"rtl_vendor\anlogic_example\lab_ex4_all_features_SC500_720P"
              r"\lab_ex4_all_features\user_source\hdl_source\hdmi_mixer.v")

IMG_W, IMG_H = 1280, 720

src = MIX.read_text(encoding="utf-8", errors="replace")

# ---------------------------------------------------------------------------
# 解析所有 localparam（迭代求值，支持 IMG_WIDTH - MODE_W 这类嵌套引用）
#   只允许数字与 + - * / ( )，用受限 eval，不执行任意代码
# ---------------------------------------------------------------------------
raw = dict(re.findall(r"localparam\s+(?:integer\s+)?(\w+)\s*=\s*([^;]+);", src))
vals = {"IMG_WIDTH": IMG_W, "IMG_HEIGHT": IMG_H}
for _ in range(8):                       # 迭代若干轮解决依赖顺序
    changed = False
    for k, e in raw.items():
        if k in vals:
            continue
        ee = re.sub(r"\d+'d(\d+)", r"\1", e)
        for name, v in sorted(vals.items(), key=lambda kv: -len(kv[0])):
            ee = re.sub(r"\b%s\b" % re.escape(name), str(v), ee)
        ee = ee.strip()
        if re.fullmatch(r"[0-9+\-*/() ]+", ee):
            try:
                vals[k] = int(eval(ee, {"__builtins__": {}}, {}))
                changed = True
            except Exception:
                pass
    if not changed:
        break

def lp(name, default=None):
    return vals.get(name, default)


# 各区域：名称 -> (x, y, w, h)
regions = {}

# 1) Logo（P1b 裁剪 ROM，屏幕原点 = LOGO_X+LOGO_ROM_X0, LOGO_Y+LOGO_ROM_Y0）
logo_x  = lp("LOGO_X", 0)
logo_y  = lp("LOGO_Y", 0)
logo_rx = lp("LOGO_ROM_X0")
logo_ry = lp("LOGO_ROM_Y0")
logo_w  = lp("LOGO_ROM_W")
logo_h  = lp("LOGO_ROM_H")
if None not in (logo_x, logo_y, logo_rx, logo_ry, logo_w, logo_h):
    regions["Logo(安路)"] = (logo_x + logo_rx, logo_y + logo_ry, logo_w, logo_h)

# 2) 安路 CNT 动态文本
dyn_x = lp("DYN_OSD_X"); dyn_y = lp("DYN_OSD_Y")
dyn_w = lp("DYN_OSD_W"); dyn_h = lp("DYN_OSD_H")
if None not in (dyn_x, dyn_y, dyn_w, dyn_h):
    regions["动态文本(CNT)"] = (dyn_x, dyn_y, dyn_w, dyn_h)

# 3) 底部状态条
st_y = lp("STATUS_Y"); st_h = lp("STATUS_H")
if None not in (st_y, st_h):
    regions["底部状态条"] = (0, st_y, IMG_W, st_h)

# 4) 右上模式数字（字形实际区，用 MODE_DW/MODE_DH）
md_x = lp("MODE_X"); md_y = lp("MODE_Y")
md_w = lp("MODE_DW"); md_h = lp("MODE_DH")
if None not in (md_x, md_y, md_w, md_h):
    regions["模式数字"] = (md_x, md_y, md_w, md_h)

# 5) P3 新增：延迟文本
lat_x = lp("LAT_X"); lat_y = lp("LAT_Y")
lat_w = lp("LAT_W"); lat_h = lp("LAT_H")
if None not in (lat_x, lat_y, lat_w, lat_h):
    regions["延迟文本(P3)"] = (lat_x, lat_y, lat_w, lat_h)

# 6) P5 新增：目标检测文字区（形状 + X,Y 坐标）
tgt_x = lp("TGT_X"); tgt_y = lp("TGT_Y")
tgt_w = lp("TGT_W"); tgt_h = lp("TGT_H")
if None not in (tgt_x, tgt_y, tgt_w, tgt_h):
    regions["目标文字(P5)"] = (tgt_x, tgt_y, tgt_w, tgt_h)

# 9) P7 新增：运动计数行（进阶要求④）
mi_x = lp("MOTINFO_X"); mi_y = lp("MOTINFO_Y")
mi_w = lp("MOTINFO_W"); mi_h = lp("MOTINFO_H")
if None not in (mi_x, mi_y, mi_w, mi_h):
    regions["运动计数行"] = (mi_x, mi_y, mi_w, mi_h)

# 8) 2026-09-26 新增：目标坐标行（进阶要求② “坐标叠加”）
tpos_x = lp("TGTPOS_X"); tpos_y = lp("TGTPOS_Y")
tpos_w = lp("TGTPOS_W"); tpos_h = lp("TGTPOS_H")
if None not in (tpos_x, tpos_y, tpos_w, tpos_h):
    regions["目标坐标行"] = (tpos_x, tpos_y, tpos_w, tpos_h)

# 7) P6 新增：AE 闭环状态行（A/M + 曝光 + 增益 + 平均亮度，全十六进制）
ae_x = lp("AEINFO_X"); ae_y = lp("AEINFO_Y")
ae_w = lp("AEINFO_W"); ae_h = lp("AEINFO_H")
if None not in (ae_x, ae_y, ae_w, ae_h):
    regions["AE状态文字(P6)"] = (ae_x, ae_y, ae_w, ae_h)

print("=" * 70)
print(" OSD 区域布局校验（从 hdmi_mixer.v 抽取常量，独立于 RTL 逻辑）")
print("=" * 70)
print("  画布: %d x %d" % (IMG_W, IMG_H))
print()
print("  区域矩形（x, y, w, h）：")
for name, (x, y, w, h) in regions.items():
    inb = "在界内" if (x >= 0 and y >= 0 and x + w <= IMG_W and y + h <= IMG_H) else "!! 越界"
    print("    %-16s (%4d,%4d)  %4dx%-4d   行 %d..%d  列 %d..%d   %s"
          % (name, x, y, w, h, y, y + h - 1, x, x + w - 1, inb))

# ---- 两两求交 ----
def overlap(a, b):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    ox = max(0, min(ax + aw, bx + bw) - max(ax, bx))
    oy = max(0, min(ay + ah, by + bh) - max(ay, by))
    return ox, oy

print()
print("  ---- 两两重叠检查 ----")
bad = 0
for n1, n2 in combinations(regions, 2):
    ox, oy = overlap(regions[n1], regions[n2])
    if ox > 0 and oy > 0:
        print("    [WARN] %-16s 与 %-16s 重叠 %d x %d 像素" % (n1, n2, ox, oy))
        bad += 1
    else:
        print("    [ OK ] %-16s 与 %-16s 不重叠" % (n1, n2))

# ---- 边界 ----
print()
print("  ---- 越界检查 ----")
oob = [n for n, (x, y, w, h) in regions.items()
       if not (x >= 0 and y >= 0 and x + w <= IMG_W and y + h <= IMG_H)]
if oob:
    print("    [NG] 越界区域: %s" % ", ".join(oob))
else:
    print("    [OK] 所有区域都在 %dx%d 画布内" % (IMG_W, IMG_H))

print()
print("=" * 70)
if bad == 0 and not oob:
    print(" [OK] 布局无重叠、无越界，共 %d 个区域" % len(regions))
else:
    print(" [NG] %d 处重叠，%d 处越界" % (bad, len(oob)))
print("=" * 70)
sys.exit(1 if (bad or oob) else 0)
