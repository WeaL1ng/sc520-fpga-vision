#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
_ensure_ps1_bom.py --- 给"含非 ASCII 字符但没有 BOM"的 .ps1 补上 UTF-8 BOM

为什么必须有这一步
------------------
PowerShell 5.1 读 **无 BOM** 的 .ps1 时按系统 ANSI 代码页（简中 = GBK）解码。
本仓库的 .ps1 是 UTF-8 编码，含中文注释 ⇒ GBK 解码会把某些 UTF-8 字节当双字节
字符吞掉，紧跟着的 `"` 或 `{` 被吃掉 ⇒ **解析期语法错误**，报错行号还落在几百行
之外（现象是"某个字符串字面量里缺少右 }"）。

实测：`tools/run_d4_ab.ps1` 因此报 3 个假错误（line 46/73/80），补 BOM 后全绿。

交接说明 §6.1.4 已记录这条；本脚本把它变成可自动检查的动作。

用法
----
    python tools/_ensure_ps1_bom.py            # 只报告
    python tools/_ensure_ps1_bom.py --apply    # 补 BOM
"""
import re
import sys
from pathlib import Path

W = Path(__file__).resolve().parent.parent
BOM = b"\xef\xbb\xbf"


def ps1_files():
    """全工程的 .ps1（跳过 _backup_* / _stage / _scratch_utf8 这些历史快照）。

    ⚠ 用 `edit`/`write` 工具改过含中文的 .ps1 之后必须重跑本脚本：
      那两个工具会剥掉 UTF-8 BOM，PowerShell 5.1 随即按 GBK 读而解析失败。
    """
    skip = re.compile(r"[\\/](_backup_[^\\/]*|_stage|_scratch_utf8|\.[^\\/]*)[\\/]")
    for p in sorted(W.rglob("*.ps1")):
        if skip.search(str(p.relative_to(W)) + "/"):
            continue
        yield p


def main():
    apply = "--apply" in sys.argv
    need = 0
    for p in ps1_files():
        raw = p.read_bytes()
        if raw.startswith(BOM):
            continue
        try:
            raw.decode("ascii")
            continue  # 纯 ASCII，不需要 BOM
        except UnicodeDecodeError:
            pass
        need += 1
        rel = p.relative_to(W).as_posix()
        print("  缺 BOM 且含非 ASCII: %s" % rel)
        if apply:
            p.write_bytes(BOM + raw)
    print()
    if need == 0:
        print("所有 .ps1 都合规（含非 ASCII 的都有 BOM）")
    else:
        print("%d 个文件%s" % (need, "已补 BOM" if apply else "需要补 BOM（加 --apply）"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
