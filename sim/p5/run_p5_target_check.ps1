# ============================================================
#  run_p5_target_check.ps1 -- P5 颜色目标检测 功能验证（一键，12 个场景）
#
#  验证链（两个互相独立的实现）
#    ① ModelSim : 编译 target_detect_96 + tb_target_detect_96，灌合成图案，
#                 每帧导出 包围框/tile数/形状 到 target_out.txt
#    ② Python   : tools/check_target_detect.py **从图案定义重新实现一遍算法**
#                 （不复用 RTL），逐帧比对；并把色度系数用整数式 vs BT.601
#                 浮点式交叉验证一遍
#
#  12 个场景：A 橙块(应检出) / B 蓝块(不应) / C 肤色(不应) / D 橙长条(应判 BAR) / E 无目标
#
#  用法：
#     powershell -ExecutionPolicy Bypass -File .\sim\p5\run_p5_target_check.ps1
# ============================================================
[CmdletBinding()]
param(
    [string]$ProjectDir = '',
    [string]$ModelSimBin = 'F:\modelsim\modelsim_ase\win32aloem',
    [string]$TbFile = '',
    [string]$CheckPy = '',
    [string]$WorkDir = ''
)

$w = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
if (-not $ProjectDir) { $ProjectDir = Join-Path $w 'rtl_vendor\anlogic_example\lab_ex4_all_features_SC500_720P\lab_ex4_all_features' }
if (-not $TbFile) { $TbFile = Join-Path $w 'sim\p5\tb_target_detect_96.v' }
if (-not $CheckPy) { $CheckPy = Join-Path $w 'tools\check_target_detect.py' }
if (-not $WorkDir) { $WorkDir = Join-Path $w '_stage\p5_sim' }

$ErrorActionPreference = 'Stop'
$vlib = Join-Path $ModelSimBin 'vlib.exe'
$vlog = Join-Path $ModelSimBin 'vlog.exe'
$vsim = Join-Path $ModelSimBin 'vsim.exe'
foreach ($t in @($vlib, $vlog, $vsim)) { if (-not (Test-Path $t)) { throw "not found: $t" } }

$rtl = Join-Path $ProjectDir 'user_source\hdl_source\isp\target_detect_96.v'
if (-not (Test-Path $rtl)) { throw "not found: $rtl" }

if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
Push-Location $WorkDir

Write-Host ''
Write-Host '===== [1/2] ModelSim: compile ====='
& $vlib work | Out-Null
$c = & $vlog -work work $rtl $TbFile 2>&1
$c | Where-Object { $_ -match 'Error|Errors:|Compiling|Warning' } | ForEach-Object { Write-Host "  $_" }
if (($c | Select-String 'Errors: 0' -Quiet) -ne $true) { Pop-Location; throw 'compile failed' }

$allRc = 0
foreach ($sc in @('A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L')) {
    Write-Host ''
    Write-Host ("===== [2/2] 场景 {0} =====" -f $sc)
    $outFile = "target_out_$sc.txt"
    $o = & $vsim -batch -lib work tb_target_detect_96 -do "run -all; quit -f" `
            "+scene=$sc" "+out=$outFile" 2>&1
    $o | Where-Object { $_ -match '\[frame|共输出|\[NG\]|Errors:' } |
        ForEach-Object { Write-Host ("  " + ($_ -replace '^\s*#\s?', '').TrimEnd()) }

    # TB 通过 +out= 直接写目标文件名
    if (-not (Test-Path $outFile)) { Pop-Location; throw "no output for scene $sc" }

    $env:PYTHONIOENCODING = 'utf-8'
    & python $CheckPy --scene $sc --out (Join-Path $WorkDir $outFile) 2>&1 |
        Where-Object { $_ -match '系数|不一致|期望|bbox=|frame |tile 命中|\[OK\]|\[NG\]|   - |warn' } |
        ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { $allRc = 1 }
}

Pop-Location
Write-Host ''
if ($allRc -eq 0) { Write-Host 'RESULT: PASS  (12 个场景全部与 Python 独立实现一致)' }
else              { Write-Host 'RESULT: FAIL' }
exit $allRc
