#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
_fix_ps1_param_defaults.py --- 第二阶段：把 param 默认值里的路径推导搬到参数块之后

为什么需要第二阶段
------------------
第一阶段的写法是

    param([string]$ProjectRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'rtl_vendor\\...'))

在 **PowerShell 5.1 里不可行**：参数默认值在 param 块绑定时求值，此时 `$PSScriptRoot`
还没被赋值 ⇒ `Split-Path : Cannot bind argument to parameter 'Path' because it is an
empty string.`（实测 `run_all_checks.ps1 -Fast` 直接崩在 param 行）。

正确写法是把推导放到 param 块**之后**（那里 `$PSScriptRoot` 有效）：

    param([string]$ProjectRoot = '')
    ...
    $w = Split-Path -Parent $PSScriptRoot
    if (-not $ProjectRoot) { $ProjectRoot = Join-Path $w 'rtl_vendor\\...' }

"调用时显式传参"的语义完全不变，只有默认值变成可搬迁的。
（不用正则解析那一行 —— 反斜杠 + 引号的组合太容易写错；这里直接按字符位置切。）

用法
----
    python tools/_fix_ps1_param_defaults.py            # dry-run
    python tools/_fix_ps1_param_defaults.py --apply
"""
import sys
from pathlib import Path

W = Path(__file__).resolve().parent.parent

PS1 = [
    "tools/build_fpga.ps1",
    "tools/make_release.ps1",
    "tools/run_d4_ab.ps1",
    "tools/run_d4_ab_launcher.ps1",
    "tools/run_all_checks.ps1",
    "tools/run_module_regression.ps1",
    "tools/run_redline1_tb.ps1",
    "tools/td_stage.ps1",
    "sim/p1b/run_p1b_logo_check.ps1",
    "sim/p3/run_p3_latency_check.ps1",
    "sim/p4/run_p4_cartoon_check.ps1",
    "sim/p5/run_p5_target_check.ps1",
    "sim/p6/run_p6_checks.ps1",
    "sim/lab_topic2/run_lab_topic2_tb.ps1",
]

MARK = "$PSScriptRoot)"


def parse_param_line(line):
    """'    [string]$X = (Join-Path (Split-Path -Parent $PSScriptRoot) 'a\\b'),'
       -> (indent, 'X', 'a\\b', ',')  否则 None"""
    s = line.rstrip("\r")
    stripped = s.strip()
    if not stripped.startswith("[string]$") or "(Join-Path " not in s:
        return None
    after = stripped[len("[string]$"):]
    if "=" not in after:
        return None
    name = after.split("=", 1)[0].strip()
    idx = s.rfind(MARK)
    if idx < 0:
        return None
    # 两级形式是 (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) —— 多一个 ')'
    rest = s[idx + len(MARK):].lstrip().lstrip(")").lstrip()
    if not rest or rest[0] not in "\"'":
        return None
    q = rest[0]
    endq = rest.rfind(q)
    if endq <= 0:
        return None
    rel = rest[1:endq]
    indent = s[: len(s) - len(s.lstrip())]
    comma = "," if s.rstrip().endswith(",") else ""
    return indent, name, rel, comma


def main():
    apply = "--apply" in sys.argv
    changed = 0
    for rel_path in PS1:
        p = W / rel_path
        if not p.exists():
            print("  [缺失] %s" % rel_path)
            continue
        raw = p.read_bytes()
        bom = raw.startswith(b"\xef\xbb\xbf")
        text = (raw[3:] if bom else raw).decode("utf-8")
        lines = text.split("\n")

        start = next((i for i, l in enumerate(lines)
                      if l.strip().lower().startswith("param(")), None)
        if start is None:
            print("%s  [跳过] 没有 param 块" % rel_path)
            continue
        end = next((i for i in range(start + 1, len(lines))
                    if lines[i].rstrip("\r") == ")"), None)
        if end is None:
            print("%s  [跳过] 找不到 param 块结尾" % rel_path)
            continue

        assigned = []
        for i in range(start, end + 1):
            got = parse_param_line(lines[i])
            if not got:
                continue
            indent, name, rel, comma = got
            lines[i] = "%s[string]$%s = ''%s" % (indent, name, comma)
            assigned.append((name, rel))

        if not assigned:
            print("%s  [跳过] param 块里没有待改的路径默认值" % rel_path)
            continue

        depth = len(rel_path.split("/")) - 1     # tools/x -> 1；sim/pX/x -> 2
        root = ("(Split-Path -Parent $PSScriptRoot)" if depth == 1
                else "(Split-Path -Parent (Split-Path -Parent $PSScriptRoot))")
        block = ["", "$w = %s" % root]
        for name, rel in assigned:
            block.append("if (-not $%s) { $%s = Join-Path $w '%s' }" % (name, name, rel))
        lines[end + 1:end + 1] = block
        new_text = "\n".join(lines)

        changed += 1
        print("%s  %d 个参数" % (rel_path, len(assigned)))
        for b in block[1:]:
            print("     %s" % b)
        if apply:
            data = new_text.encode("utf-8")
            p.write_bytes(b"\xef\xbb\xbf" + data if bom else data)

    print()
    print("%d 个文件%s" % (changed, "已改" if apply else "（dry-run，加 --apply 写回）"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
