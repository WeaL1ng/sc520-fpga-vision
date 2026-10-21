# ============================================================================
#  run_module_regression.ps1 --- 模块级回归（P0~P4 全量，一键）
#
#  为什么需要
#    P4 改的不只是新模块：还动了 `isp_top.v`（数据通路 mux + 模式位宽）、
#    `key_mode_ctrl.v`（取模 5 循环）、`design_top_wrapper.v`（同步器位宽）、
#    `hdmi_mixer.v`（I_mode_disp[2:0] / F_mode7seg[3:0]）。
#    ⇒ **必须证明前面几个阶段的功能没有被 P4 破坏**（P4 报告验收清单第 7 条）。
#
#  跑哪些（全部针对**当前正式工程的 RTL**，不是冻结副本）
#    ① tb_key_mode_ctrl   —— P4 改了模式循环（0→1→2→3→4→0）
#    ② tb_gray_binary_96  —— 红线1 的 4 模式（0..3），P4 之后必须仍正确
#    ③ tb_frame_latency   —— P3 的延迟测量（不得回退）
#    ④ tb_hdmi_mixer_logo —— P1b/P3 的 Logo + OSD（P4 改过 hdmi_mixer 端口）
#
#  ⚠ 每个 case 独立 work 目录，失败不互相污染；任一 case 失败则整体 exit 1。
#
#  用法：
#     powershell -ExecutionPolicy Bypass -File .\tools\run_module_regression.ps1
# ============================================================================
[CmdletBinding()]
param(
    [string]$ProjectRoot = '',
    [string]$ModelSimBin = 'F:\modelsim\modelsim_ase\win32aloem',
    [string]$WorkRoot = ''
)

$w = (Split-Path -Parent $PSScriptRoot)
if (-not $ProjectRoot) { $ProjectRoot = Join-Path $w 'rtl_vendor\anlogic_example\lab_ex4_all_features_SC500_720P\lab_ex4_all_features' }
if (-not $WorkRoot) { $WorkRoot = Join-Path $w '_stage\module_regress' }

$ErrorActionPreference = 'Stop'
$w    = (Split-Path -Parent $PSScriptRoot)
$hdl  = Join-Path $ProjectRoot 'user_source\hdl_source'
$isp  = Join-Path $hdl 'isp'
$vlib = Join-Path $ModelSimBin 'vlib.exe'
$vlog = Join-Path $ModelSimBin 'vlog.exe'
$vsim = Join-Path $ModelSimBin 'vsim.exe'
foreach ($t in @($vlib, $vlog, $vsim)) { if (-not (Test-Path $t)) { throw "not found: $t" } }

# ---- case 定义：name / 源文件 / 顶层 / 期望的失败特征 ----
$cases = @(
    @{ name = 'key_mode_ctrl'; tb = 'tb';       top = 'tb_key_mode_ctrl';
       src = @((Join-Path $hdl 'key_mode_ctrl.v'), (Join-Path $w 'sim\tb\tb_key_mode_ctrl.v')) },
    @{ name = 'gray_binary_96'; tb = 'redline1'; top = 'tb_gray_binary_96';
       src = @((Join-Path $isp 'gray_binary_96.v'), (Join-Path $w 'sim\redline1\tb_gray_binary_96.v')) },
    @{ name = 'frame_latency'; tb = 'p3'; top = 'tb_frame_latency_bank';
       src = @((Join-Path $hdl 'frame_latency.v'), (Join-Path $w 'sim\p3\tb_frame_latency_bank.v')) },
    @{ name = 'hdmi_mixer_logo'; tb = 'p1b'; top = 'tb_hdmi_mixer_logo';
       src = @((Join-Path $hdl 'hdmi_mixer.v'), (Join-Path $hdl 'logo_rom_eram.v'),
               (Join-Path $hdl 'osd_char_lib.v'), (Join-Path $w 'sim\p1b\tb_hdmi_mixer_logo.v')) }
)

if (Test-Path $WorkRoot) { Remove-Item $WorkRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null

$failed = @()
foreach ($c in $cases) {
    Write-Host ''
    Write-Host ("===== case: {0} =====" -f $c.name)
    foreach ($s in $c.src) { if (-not (Test-Path $s)) { throw "missing source: $s" } }
    $d = Join-Path $WorkRoot $c.name
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    Push-Location $d
    try {
        & $vlib work | Out-Null
        $cc = & $vlog -work work @($c.src) 2>&1
        $cc | Where-Object { $_ -match 'Error|Errors:|Compiling' } | ForEach-Object { Write-Host "  $_" }
        if (($cc | Select-String 'Errors: 0' -Quiet) -ne $true) {
            $failed += "$($c.name): compile failed"
            Write-Host "  [NG] compile failed"
            continue
        }
        $o = & $vsim -batch -lib work $c.top -do "run -all; quit -f" 2>&1
        $o | Set-Content -Path (Join-Path $d 'sim.log') -Encoding UTF8
        $o | Where-Object { $_ -match '\[PASS\]|\[FAIL\]|\[OK\]|\[NG\]|PASS =|FAIL =|DE pixel|done' } |
            ForEach-Object { Write-Host ("  " + ($_ -replace '^\s*#\s?', '').TrimEnd()) }

        $nfail = 0
        $mf = $o | Select-String -Pattern 'FAIL = (\d+)'
        if ($mf) { $nfail = [int]$mf.Matches[$mf.Matches.Count - 1].Groups[1].Value }
        if ($nfail -gt 0 -or ($o | Select-String '\[NG\]' -Quiet)) {
            $failed += "$($c.name): $nfail assertion(s) failed"
        }
    } finally { Pop-Location }
}

Write-Host ''
Write-Host '============================================================'
if ($failed.Count -eq 0) {
    Write-Host ' 模块级回归：全部通过（P0~P4 功能未被破坏）' -ForegroundColor Green
} else {
    Write-Host (' 模块级回归：{0} 个 case 失败' -f $failed.Count) -ForegroundColor Red
    $failed | ForEach-Object { Write-Host "   - $_" }
}
Write-Host (" 日志目录: {0}" -f $WorkRoot)
Write-Host '============================================================'
exit ([int]($failed.Count -gt 0))
