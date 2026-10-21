# ============================================================
#  run_p6_checks.ps1 -- P6 (AE closed loop) one-click verification
#
#  Chain (two mutually independent implementations, same as P5):
#    1) ModelSim : tb_luma_stats  (uniform 6 cases, TB self-checks) + (ramp dump)
#                  tb_ae_ctrl     (12 open-loop assertions + closed-loop convergence)
#    2) Python   : tools/check_luma_stats.py
#                  - exhaustive check of the CSD shift-add decompositions
#                  - integer luma vs BT.601 float cross-check
#                  - exhaustive check of the average-luma reciprocal approximation
#                  - ramp frame sum/clip/dark/avg recomputed from the pattern spec
#
#  NOTE: this script is intentionally **ASCII only**.  A .ps1 containing Chinese
#  must carry a UTF-8 BOM or PowerShell 5.1 reads it as GBK and fails to parse.
#
#  Usage:
#     powershell -ExecutionPolicy Bypass -File .\sim\p6\run_p6_checks.ps1
# ============================================================
[CmdletBinding()]
param(
    [string]$ProjectDir = '',
    [string]$ModelSimBin = 'F:\modelsim\modelsim_ase\win32aloem',
    [string]$WorkDir = ''
)

$w = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
if (-not $ProjectDir) { $ProjectDir = Join-Path $w 'rtl_vendor\anlogic_example\lab_ex4_all_features_SC500_720P\lab_ex4_all_features' }
if (-not $WorkDir) { $WorkDir = Join-Path $w '_stage\p6_sim' }

$ErrorActionPreference = 'Stop'
$vlib = Join-Path $ModelSimBin 'vlib.exe'
$vlog = Join-Path $ModelSimBin 'vlog.exe'
$vsim = Join-Path $ModelSimBin 'vsim.exe'
foreach ($t in @($vlib, $vlog, $vsim)) { if (-not (Test-Path $t)) { throw "not found: $t" } }

$rtlLuma = Join-Path $ProjectDir 'user_source\hdl_source\isp\luma_stats.v'
$rtlAe   = Join-Path $ProjectDir 'user_source\hdl_source\ae_ctrl.v'
$tbLuma  = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'sim\p6\tb_luma_stats.v')
$tbAe    = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'sim\p6\tb_ae_ctrl.v')
$checkPy = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'tools\check_luma_stats.py')
foreach ($t in @($rtlLuma, $rtlAe, $tbLuma, $tbAe, $checkPy)) {
    if (-not (Test-Path $t)) { throw "not found: $t" }
}

if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
Push-Location $WorkDir

$rc = 0

Write-Host ''
Write-Host '===== [1/5] ModelSim: compile luma_stats ====='
& $vlib work | Out-Null
$c = & $vlog -work work $rtlLuma $tbLuma 2>&1
$c | Where-Object { $_ -match 'Error|Errors:' } | ForEach-Object { Write-Host "  $_" }
if (($c | Select-String 'Errors: 0' -Quiet) -ne $true) { Pop-Location; throw 'compile failed (luma_stats)' }

Write-Host ''
Write-Host '===== [2/5] tb_luma_stats : uniform (TB self-check, 6 colors) ====='
$o = & $vsim -batch -lib work tb_luma_stats -do "run -all; quit -f" '+out=luma_uni.txt' 2>&1
$o | Where-Object { $_ -match '\[ OK \]|\[NG\]|PASS|FAIL|settled|flips' } |
    ForEach-Object { Write-Host ("  " + ($_ -replace '^\s*#\s?', '').TrimEnd()) }
if (($o | Select-String '==== PASS ====' -Quiet) -ne $true) { $rc = 1 }

Write-Host ''
Write-Host '===== [3/5] tb_luma_stats : ramp (dump for Python cross-check) ====='
$o = & $vsim -batch -lib work tb_luma_stats -do "run -all; quit -f" '+ramp=1' '+out=luma_ramp.txt' 2>&1
$o | Where-Object { $_ -match '\[dump\]|PASS|FAIL|settled' } |
    ForEach-Object { Write-Host ("  " + ($_ -replace '^\s*#\s?', '').TrimEnd()) }
if (($o | Select-String '==== PASS ====' -Quiet) -ne $true) { $rc = 1 }

Write-Host ''
Write-Host '===== [4/5] ModelSim: compile + run ae_ctrl ====='
$c = & $vlog -work work $rtlAe $tbAe 2>&1
$c | Where-Object { $_ -match 'Error|Errors:' } | ForEach-Object { Write-Host "  $_" }
if (($c | Select-String 'Errors: 0' -Quiet) -ne $true) { Pop-Location; throw 'compile failed (ae_ctrl)' }
$o = & $vsim -batch -lib work tb_ae_ctrl -do "run -all; quit -f" 2>&1
$o | Where-Object { $_ -match '\[ OK \]|\[NG\]|\[!!\]|PASS|FAIL|converge|quiet|luma=' } |
    ForEach-Object { Write-Host ("  " + ($_ -replace '^\s*#\s?', '').TrimEnd()) }
if (($o | Select-String '==== PASS ====' -Quiet) -ne $true) { $rc = 1 }

Write-Host ''
Write-Host '===== [5/5] Python: check_luma_stats.py (independent model) ====='
$env:PYTHONIOENCODING = 'utf-8'
& python $checkPy --ramp (Join-Path $WorkDir 'luma_ramp.txt') 2>&1 |
    Where-Object { $_ -match 'OK|NG|SKIP|max|expected|deviation|====' } |
    ForEach-Object { Write-Host "  $_" }
if ($LASTEXITCODE -ne 0) { $rc = 1 }

Pop-Location
Write-Host ''
if ($rc -eq 0) { Write-Host 'RESULT: PASS  (P6 L1 + L2 all green)' }
else           { Write-Host 'RESULT: FAIL' }
exit $rc
