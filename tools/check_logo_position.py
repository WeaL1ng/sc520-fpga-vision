#!/usr/bin/env python3
# ============================================================
#  check_logo_position.py -- P1b Logo 绝对位置验证（独立第二实现）
#
#  方法：不依赖任何对"背景编码"的假设，用两次仿真做差
#     run A: +osd=0  -> 无 Logo（I_osd_en=0）
#     run B: +osd=1  -> 有 Logo（I_osd_en=1）
#     两次除 OSD 开关外激励完全相同 => 逐像素做差，差集 = Logo 的精确覆盖区
#    （状态条与模式数字不受 I_osd_en 影响，两次都有，做差后自动消掉）
#
#  期望侧：直接解析 logo_pixel.mif + logo_palette.vh，展开 146x94 的非透明
#          包围盒，再按 P1b 几何换算到屏幕坐标。
#
#  两侧一致 => Logo 无 1 像素偏移。
#
#  用法：
#    python tools\check_logo_position.py --sim-dir _stage\multisim \
#           --no-osd logo_osd0.hex --with-osd logo_osd1.hex
# ============================================================
import argparse
import os
import re
import sys

IMG_W = 1280
IMG_H = 720

# P1b 屏幕几何（与 hdmi_mixer.v 的 localparam 一致）
LOGO_X, LOGO_Y = 0, 0
ROM_X0, ROM_Y0 = 7, 34
ROM_W, ROM_H = 146, 94


def parse_palette(path):
    txt = open(path, 'r', encoding='utf-8', errors='replace').read()
    pal = {}
    for m in re.finditer(r"12'd(\d+)\s*:\s*logo_palette\s*=\s*24'h([0-9a-fA-F]{6})", txt):
        pal[int(m.group(1))] = int(m.group(2), 16)
    return pal


def parse_mif(path):
    depth, data, content = None, {}, False
    for line in open(path, 'r', encoding='utf-8', errors='replace'):
        s = line.strip()
        if not s or s.startswith('--'):
            continue
        m = re.match(r'DEPTH\s*=\s*(\d+)', s, re.I)
        if m:
            depth = int(m.group(1)); continue
        if re.match(r'CONTENT\s+BEGIN', s, re.I):
            content = True; continue
        if re.match(r'END\s*;', s, re.I):
            content = False; continue
        if not content:
            continue
        m = re.match(r'(\d+)\s*:\s*([0-9a-fA-F]+)\s*;?$', s)
        if m:
            data[int(m.group(1))] = int(m.group(2), 16)
            continue
        m = re.match(r'\[\s*(\d+)\s*\.\.\s*(\d+)\s*\]\s*:\s*([0-9a-fA-F]+)\s*;?$', s)
        if m:
            for i in range(int(m.group(1)), int(m.group(2)) + 1):
                data[i] = int(m.group(3), 16)
    return depth, data


def expected_bbox(pal, data):
    minx, miny, maxx, maxy = 10**9, 10**9, -1, -1
    nonzero = 0
    for a in range(ROM_W * ROM_H):
        idx = data.get(a, 0)
        if idx == 0:
            continue
        if idx not in pal:
            raise SystemExit('mif index %d not in palette' % idx)
        dy, dx = divmod(a, ROM_W)
        nonzero += 1
        minx = min(minx, dx); maxx = max(maxx, dx)
        miny = min(miny, dy); maxy = max(maxy, dy)
    if nonzero == 0:
        raise SystemExit('mif has no non-transparent pixel')
    return dict(nonzero=nonzero,
                local=(minx, miny, maxx - minx + 1, maxy - miny + 1),
                screen=(LOGO_X + ROM_X0 + minx, LOGO_Y + ROM_Y0 + miny,
                        maxx - minx + 1, maxy - miny + 1))


def load_hex(path):
    lines = [l.strip() for l in open(path, 'r') if l.strip()]
    return [int(s, 16) & 0xFFFFFF for s in lines]


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument('--logo-dir', default=os.path.join(here, 'logo_rom'))
    ap.add_argument('--sim-dir', required=True)
    ap.add_argument('--no-osd', default='logo_osd0.hex')
    ap.add_argument('--with-osd', default='logo_osd1.hex')
    args = ap.parse_args()

    mif = os.path.join(args.logo_dir, 'logo_pixel.mif')
    pal_vh = os.path.join(args.logo_dir, 'logo_palette.vh')
    fa = os.path.join(args.sim_dir, args.no_osd)
    fb = os.path.join(args.sim_dir, args.with_osd)
    for f in (mif, pal_vh, fa, fb):
        if not os.path.exists(f):
            sys.exit('missing file: %s' % f)

    pal = parse_palette(pal_vh)
    depth, data = parse_mif(mif)
    exp = expected_bbox(pal, data)

    print('=' * 68)
    print(' EXPECTED side (computed from logo_pixel.mif + logo_palette.vh)')
    print('=' * 68)
    print('  ROM depth              : %d' % depth)
    print('  palette colours        : %d' % len(pal))
    print('  non-transparent pixels : %d' % exp['nonzero'])
    print('  local  bbox (x,y,w,h)  : %s' % (exp['local'],))
    print('  SCREEN bbox (x,y,w,h)  : %s   <-- where the Logo must appear' % (exp['screen'],))

    A = load_hex(fa)
    B = load_hex(fb)
    print('')
    print('=' * 68)
    print(' MEASURED side (two ModelSim runs, diffed pixel by pixel)')
    print('=' * 68)
    print('  run A (+osd=0) pixels  : %d' % len(A))
    print('  run B (+osd=1) pixels  : %d' % len(B))
    if len(A) != IMG_W * IMG_H or len(B) != IMG_W * IMG_H:
        sys.exit('pixel count mismatch: A=%d B=%d, expect %d' % (len(A), len(B), IMG_W*IMG_H))
    print('  both runs cover        : %dx%d = %d  OK' % (IMG_W, IMG_H, IMG_W*IMG_H))

    minx, miny, maxx, maxy = 10**9, 10**9, -1, -1
    diff_cnt = 0
    pal_rgb = set(pal.values())
    pal_hits = 0
    not_in_pal = 0
    # OSD 里除了 Logo 还有"安路 CNT"动态文字（在 x=375..575, y=120..145）。
    # 为了单独量 Logo，把统计范围限制在 Logo 可能出现的窗口内。
    # 窗口取 P1b 裁剪区屏幕范围再向四周各留 8 像素余量，用于探测偏移：
    #   Logo 应在 x in [7,153) y in [34,128)
    win_x0, win_y0 = ROM_X0 - 8, ROM_Y0 - 8
    win_x1, win_y1 = ROM_X0 + ROM_W + 8, ROM_Y0 + ROM_H + 8
    outside_win = 0
    for i in range(len(A)):
        if A[i] == B[i]:
            continue
        y, x = divmod(i, IMG_W)
        ## 窗口外的差异（应为动态文字）单独计数，不参与 Logo 包围盒
        if not (win_x0 <= x < win_x1 and win_y0 <= y < win_y1):
            outside_win += 1
            continue
        diff_cnt += 1
        if B[i] in pal_rgb:
            pal_hits += 1
        else:
            not_in_pal += 1
        minx = min(minx, x); maxx = max(maxx, x)
        miny = min(miny, y); maxy = max(maxy, y)

    print('  Logo window searched   : x[%d,%d) y[%d,%d)' % (win_x0, win_x1, win_y0, win_y1))
    print('  diffs OUTSIDE window   : %d   (the 安路 CNT dynamic text)' % outside_win)
    print('  pixels differing IN win: %d   (= Logo-covered pixels)' % diff_cnt)
    print('    of which in palette  : %d' % pal_hits)
    print('    not in palette       : %d' % not_in_pal)
    if diff_cnt == 0:
        print('')
        print('  [FAIL] no pixel differs -> the Logo is NOT drawn at all')
        return 2
    got = (minx, miny, maxx - minx + 1, maxy - miny + 1)
    print('  MEASURED bbox (x,y,w,h): %s' % (got,))

    print('')
    print('=' * 68)
    print(' COMPARISON')
    print('=' * 68)
    e = exp['screen']
    print('  expected: x=%-5d y=%-5d w=%-5d h=%-5d' % e)
    print('  measured: x=%-5d y=%-5d w=%-5d h=%-5d' % got)
    dx, dy = got[0] - e[0], got[1] - e[1]
    dw, dh = got[2] - e[2], got[3] - e[3]
    print('  delta   : dx=%-+5d dy=%-+5d dw=%-+5d dh=%-+5d' % (dx, dy, dw, dh))
    print('')
    ok = (dx == 0 and dy == 0 and dw == 0 and dh == 0)
    if ok:
        print('  [PASS] Logo position and size match exactly - no 1-pixel shift')
    else:
        print('  [FAIL] Logo position/size mismatch')
        if dx or dy:
            print('         offset (dx,dy) = (%+d,%+d)' % (dx, dy))
            if dx == 1 and dy == 1:
                print('         both +1  -> the _1d address stage still ends up 1 cycle LATE')
            if dx == -1 and dy == -1:
                print('         both -1  -> still 1 cycle SHORT')
        if dw or dh:
            print('         size differs -> cropped region / ROM address mapping wrong')
    print('=' * 68)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
