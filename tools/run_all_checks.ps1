# ============================================================
#  run_all_checks.ps1 -- 一键跑完 L1~L3 全部自动判据
#
#  判断依据见 doc\analysis\验收标准与证据链.md（证据分级 L0~L4）。
#
#  ★ 这个脚本**只能判到 L3**（仿真 / 独立模型 / 综合布线）。
#    L4（功能真的在板上工作）必须人工目视 —— 本项目 2026-09-21 的教训就是
#    "frame_latency 在 L1 是 8/8 全绿，一上板发现算的压根不是延迟"。
#
#  覆盖的判据
#    L1  ModelSim 断言：
#         · tools\run_module_regression.ps1   （key_mode_ctrl 16 / gray 58 / 延迟 8×2 / logo DE）
#         · sim\p4\run_p4_cartoon_check.ps1   （卡通 3 场景 × 3 断言）
#         · sim\p3\run_p3_latency_check.ps1   （延迟 8 × 2 场景，含旧算法复现）
#         · sim\p1b\run_p1b_logo_check.ps1    （Logo 位置，约 4.5 分钟；-Fast 可跳）
#    L2  Python 独立模型：
#         · tools\verify_font_roundtrip.py    （77 字形往返）
#         · tools\verify_osd_layout.py        （5 个 OSD 区域无重叠无越界）
#    L3  TD 报告独立解析：
#         · tools\verify_td_reports.py        （资源/零违例/各域 Fmax/关键模块）
#
#  用法：
#     powershell -ExecutionPolicy Bypass -File .\tools\run_all_checks.ps1
#     powershell -ExecutionPolicy Bypass -File .\tools\run_all_checks.ps1 -Build
#     powershell -ExecutionPolicy Bypass -File .\tools\run_all_checks.ps1 -Fast
# ============================================================
[CmdletBinding()]
param(
    [string]$ProjectRoot = '',
    [switch]$Build,
    [switch]$Fast
)

$w = (Split-Path -Parent $PSScriptRoot)
if (-not $ProjectRoot) { $ProjectRoot = Join-Path $w 'rtl_vendor\anlogic_example\lab_ex4_all_features_SC500_720P\lab_ex4_all_features' }

$ErrorActionPreference = 'Continue'
$w = (Split-Path -Parent $PSScriptRoot)
$env:PYTHONIOENCODING = 'utf-8'

$script:results = @()

function Invoke-Check {
    param(
        [string]$Layer,
        [string]$Name,
        [string]$Cmd,          # 完整命令行（用 cmd /c 走一遍，保证退出码可见）
        [double]$TimeoutMin = 20
    )
    Write-Host ''
    Write-Host ('=' * 70)
    Write-Host (" [{0}] {1}" -f $Layer, $Name)
    Write-Host ('=' * 70)
    $t0 = Get-Date
    $out = & cmd /c $Cmd 2>&1
    $rc  = $LASTEXITCODE
    $el  = ((Get-Date) - $t0).TotalSeconds
    # 只回显关键行，避免刷屏
    $out | Where-Object {
        $_ -match 'PASS|FAIL|\[OK\]|\[NG\]|exit=|RESULT|门禁|Errors:|个问题|越界|OK\]|超 80'
    } | Select-Object -Last 12 | ForEach-Object { Write-Host ("   " + $_.ToString().TrimEnd()) }
    Write-Host ("   -> exit={0}  ({1:N0}s)" -f $rc, $el)
    $script:results += [pscustomobject]@{
        Layer = $Layer; Name = $Name; Exit = $rc; Sec = [int]$el
    }
}

# ---------------------------------------------------------------- 可选重构建
if ($Build) {
    Invoke-Check -Layer 'L3' -Name 'TD 综合 + 布线 + bitgen（约 16 分钟）' `
        -Cmd "powershell -ExecutionPolicy Bypass -File `"$w\tools\build_fpga.ps1`" -Stage all -ProjectRoot `"$ProjectRoot`""
}

# ---------------------------------------------------------------- L1
Invoke-Check -Layer 'L1' -Name '模块回归（模式循环/灰度/延迟/Logo OSD）' `
    -Cmd "powershell -ExecutionPolicy Bypass -File `"$w\tools\run_module_regression.ps1`" -ProjectRoot `"$ProjectRoot`""

Invoke-Check -Layer 'L1' -Name '卡通化 3 场景逐像素（ModelSim + Python 独立核对）' `
    -Cmd "powershell -ExecutionPolicy Bypass -File `"$w\sim\p4\run_p4_cartoon_check.ps1`" -ProjectDir `"$ProjectRoot`""

Invoke-Check -Layer 'L1' -Name '延迟测量 2 场景（含旧算法缺陷复现）' `
    -Cmd "powershell -ExecutionPolicy Bypass -File `"$w\sim\p3\run_p3_latency_check.ps1`" -ProjectDir `"$ProjectRoot`""

Invoke-Check -Layer 'L1' -Name '目标检测 12 场景逐帧（含肤色/蓝/黄/过曝/哑光橙/暗光场景 + BCD 位）' `
    -Cmd "powershell -ExecutionPolicy Bypass -File `"$w\sim\p5\run_p5_target_check.ps1`" -ProjectDir `"$ProjectRoot`""

Invoke-Check -Layer 'L1' -Name 'AE 闭环：亮度统计 6 色 + 控制器 12 条断言 + 闭环收敛' `
    -Cmd "powershell -ExecutionPolicy Bypass -File `"$w\sim\p6\run_p6_checks.ps1`" -ProjectDir `"$ProjectRoot`""

if (-not $Fast) {
    Invoke-Check -Layer 'L1' -Name 'Logo 位置回归（两次仿真做差，约 4.5 分钟）' `
        -Cmd "powershell -ExecutionPolicy Bypass -File `"$w\sim\p1b\run_p1b_logo_check.ps1`" -ProjectDir `"$ProjectRoot`""
}

# ---------------------------------------------------------------- L2
Invoke-Check -Layer 'L2' -Name 'OSD 字库 77 字形往返一致' `
    -Cmd "python `"$w\tools\verify_font_roundtrip.py`""

Invoke-Check -Layer 'L2' -Name 'OSD 9 个区域无重叠 / 无越界' `
    -Cmd "python `"$w\tools\verify_osd_layout.py`""

Invoke-Check -Layer 'L2' -Name '亮度统计独立模型（CSD 穷举 / BT.601 交叉核对 / 平均亮度误差）' `
    -Cmd "python `"$w\tools\check_luma_stats.py`" --ramp `"$w\_stage\p6_sim\luma_ramp.txt`""

#  ★ 2026-09-27 新增：TILE_HIT_TH 判别力。
#    这条守的是"暗光下零星色度噪声不得被当成暖色目标"——
#    上板症状是**框占满屏/偏低**，而 L1 的 12 个场景全是实心填充，
#    结构上查不出这一类（噪声是零星、目标是成片，必须专门造噪声）。
Invoke-Check -Layer 'L2' -Name 'tile 命中门槛判别力（实心目标不误杀 / 零星噪声能挡住）' `
    -Cmd "python `"$w\tools\check_tile_hit_th.py`""

# ---------------------------------------------------------------- L3
Invoke-Check -Layer 'L3' -Name 'TD 报告独立解析（资源 / 零违例 / 各域 Fmax / 关键模块）' `
    -Cmd "python `"$w\tools\verify_td_reports.py`""

# ---------------------------------------------------------------- 总表
Write-Host ''
Write-Host ('=' * 70)
Write-Host ' 总表（L1~L3 自动判据；L4 上板目视必须人工做）'
Write-Host ('=' * 70)
Write-Host (" {0,-5} {1,-52} {2,6} {3,8}" -f '层', '检查项', '结果', '耗时(s)')
Write-Host (' ' + '-' * 72)
$bad = 0
foreach ($r in $script:results) {
    $tag = if ($r.Exit -eq 0) { 'PASS' } else { 'FAIL'; }
    if ($r.Exit -ne 0) { $bad++ }
    $nm = $r.Name
    if ($nm.Length -gt 50) { $nm = $nm.Substring(0, 48) + '..' }
    Write-Host (" {0,-5} {1,-52} {2,6} {3,8}" -f $r.Layer, $nm, $tag, $r.Sec)
}
Write-Host ''
if ($bad -eq 0) {
    Write-Host ' [OK] L1~L3 全部通过' -ForegroundColor Green
    Write-Host '      ⚠ 这不等于功能实现 —— 请按 doc\analysis\验收标准与证据链.md §2 做 L4 上板目视。'
} else {
    Write-Host (" [NG] {0} 项失败" -f $bad) -ForegroundColor Red
}
Write-Host ''
exit ([int]($bad -gt 0))
