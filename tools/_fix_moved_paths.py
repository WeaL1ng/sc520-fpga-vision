#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
_fix_moved_paths.py --- 把硬编码的旧工作区绝对路径改成"从脚本自身位置推导"

背景
----
工作区从 `C:\\Users\\28226\\Desktop\\siti2` 搬到了 `E:\\siti2`。
tools/ 与 sim/ 下约 25 个脚本把旧绝对路径写死在 param 默认值和常量里，
搬完之后 `run_all_checks.ps1 -Fast` 变成 10/10 FAIL（每项 exit=2，耗时 0s），
`verify_td_reports.py` 直接 FileNotFoundError。

规则
----
  .ps1  : 'C:\\...\\siti2'                -> (Split-Path -Parent $PSScriptRoot)
          'C:\\...\\siti2\\rtl_vendor\\x'  -> (Join-Path (Split-Path -Parent $PSScriptRoot) 'rtl_vendor\\x')
          单引号/双引号都处理；sim/pX/ 下的脚本向上两级。
  .py   : Path(r"C:\\...\\siti2\\a\\b")   -> Path(__file__).resolve().parent.parent.joinpath("a", "b")
          多行拼接的两个特例（dump_osd_font.py / verify_pin_assign.py）单独硬编码。

用法
----
    python tools/_fix_moved_paths.py            # 只报告，不改文件（dry-run）
    python tools/_fix_moved_paths.py --apply    # 真正写回

注意
----
* 保留原文件的 BOM 与换行符 —— 带中文的 .ps1 丢了 BOM，PowerShell 5.1 会按 GBK 读而解析失败。
* 写回前每个文件都做一次"还剩不剩旧路径"自检。
"""
import re
import sys
from pathlib import Path

W = Path(__file__).resolve().parent.parent
OLD = r"C:\Users\28226\Desktop\siti2"

PS1_TOOLS = [
    "tools/build_fpga.ps1",
    "tools/make_release.ps1",
    "tools/run_d4_ab.ps1",
    "tools/run_d4_ab_launcher.ps1",
    "tools/run_all_checks.ps1",
    "tools/run_module_regression.ps1",
    "tools/run_redline1_tb.ps1",
    "tools/td_stage.ps1",
]

PS1_SIM = [
    "sim/p1b/run_p1b_logo_check.ps1",
    "sim/p3/run_p3_latency_check.ps1",
    "sim/p4/run_p4_cartoon_check.ps1",
    "sim/p5/run_p5_target_check.ps1",
    "sim/p6/run_p6_checks.ps1",
    "sim/lab_topic2/run_lab_topic2_tb.ps1",
]

PY_GENERIC = [
    "tools/gen_osd_char_lib.py",
    "tools/verify_osd_char_lib.py",
    "tools/verify_osd_layout.py",
    "tools/verify_td_reports.py",
    "tools/verify_font_roundtrip.py",
    "tools/check_cartoon.py",
    "tools/check_target_detect.py",
    "tools/check_motion_detect.py",
]

# 多行拼接的特例：(相对路径, 原文, 替换后)
PY_SPECIAL = [
    (
        "tools/dump_osd_font.py",
        'LIB = Path(r"C:\\Users\\28226\\Desktop\\siti2\\rtl_vendor\\anlogic_example"\n'
        '           r"\\lab_ex4_all_features_SC500_720P\\lab_ex4_all_features"\n'
        '           r"\\user_source\\hdl_source\\osd_char_lib.v")',
        'LIB = (Path(__file__).resolve().parent.parent\n'
        '       / "rtl_vendor" / "anlogic_example"\n'
        '       / "lab_ex4_all_features_SC500_720P" / "lab_ex4_all_features"\n'
        '       / "user_source" / "hdl_source" / "osd_char_lib.v")',
    ),
    (
        "tools/verify_pin_assign.py",
        'BASE = (r"C:\\Users\\28226\\Desktop\\siti2\\rtl_vendor\\anlogic_example"\n'
        '        r"\\lab_ex4_all_features_SC500_720P\\lab_ex4_all_features")',
        'BASE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),\n'
        '                    r"rtl_vendor\\anlogic_example\\lab_ex4_all_features_SC500_720P\\lab_ex4_all_features")',
    ),
]


def root_expr(rel: str) -> str:
    """PowerShell 表达式：工作区根目录."""
    return "(Split-Path -Parent $PSScriptRoot)" if rel.count("/") == 1 else \
           "(Split-Path -Parent (Split-Path -Parent $PSScriptRoot))"


def fix_ps1(rel: str, text: str):
    """把脚本里所有旧绝对路径字面量换成表达式."""
    rex = root_expr(rel)
    hits = []

    def sub(m):
        quote, tail = m.group(1), m.group(2) or ""
        if not tail:
            hits.append(m.group(0))
            return rex
        inner = tail.lstrip("\\")
        hits.append(m.group(0))
        return "(Join-Path %s %s%s%s)" % (rex, quote, inner, quote)

    # 匹配 'C:\...' 或 "C:\..."，可选其后 \子路径（直到引号结束）
    pat = re.compile(r"(['\"])" + re.escape(OLD) + r"([^'\"]*)\1")
    return pat.sub(sub, text), hits


def py_join_expr(inner: str) -> str:
    parts = [p for p in inner.replace("\\", "/").split("/") if p]
    base = "Path(__file__).resolve().parent.parent"
    if not parts:
        return base
    return base + ".joinpath(" + ", ".join('"%s"' % p for p in parts) + ")"


def fix_py_generic(text: str):
    hits = []
    pat = re.compile(r'Path\(r"' + re.escape(OLD) + r'((?:\\[^"]*)?)"\)')

    def sub(m):
        hits.append(m.group(0))
        return py_join_expr(m.group(1))

    return pat.sub(sub, text), hits


def read_text(p: Path):
    raw = p.read_bytes()
    bom = raw.startswith(b"\xef\xbb\xbf")
    text = raw[3:].decode("utf-8") if bom else raw.decode("utf-8")
    return text, bom


def write_text(p: Path, text: str, bom: bool):
    data = text.encode("utf-8")
    if bom:
        data = b"\xef\xbb\xbf" + data
    p.write_bytes(data)


def main():
    apply = "--apply" in sys.argv
    total = 0
    for rel in PS1_TOOLS + PS1_SIM:
        p = W / rel
        if not p.exists():
            print("  [缺失] %s" % rel)
            continue
        text, bom = read_text(p)
        if OLD not in text:
            continue
        new, hits = fix_ps1(rel, text)
        total += len(hits)
        print("%s  %d 处  (BOM=%s)" % (rel, len(hits), bom))
        for h in hits:
            print("     - %s" % h)
        if apply:
            write_text(p, new, bom)
            left = OLD in read_text(p)[0]
            print("     -> 已写回，残留旧路径: %s" % left)

    for rel in PY_GENERIC:
        p = W / rel
        if not p.exists():
            print("  [缺失] %s" % rel)
            continue
        text, bom = read_text(p)
        if OLD not in text:
            continue
        new, hits = fix_py_generic(text)
        total += len(hits)
        print("%s  %d 处  (BOM=%s)" % (rel, len(hits), bom))
        for h in hits:
            print("     - %s" % h)
        if apply:
            write_text(p, new, bom)
            print("     -> 已写回，残留旧路径: %s" % (OLD in read_text(p)[0]))

    for rel, old, new_txt in PY_SPECIAL:
        p = W / rel
        if not p.exists():
            print("  [缺失] %s" % rel)
            continue
        text, bom = read_text(p)
        if old not in text:
            print("%s  [未匹配] 特例原文没找到（可能已改过）" % rel)
            continue
        total += 1
        print("%s  1 处（多行特例）" % rel)
        if apply:
            write_text(p, text.replace(old, new_txt, 1), bom)
            print("     -> 已写回，残留旧路径: %s" % (OLD in read_text(p)[0]))

    print()
    print("合计 %d 处  %s" % (total, "已写回" if apply else "（dry-run，未改文件；加 --apply 写回）"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
