# ============================================================
#  run_p4_cartoon_check.ps1 -- P4 卡通化 功能验证（一键，多软件）
#
#  验证链（两个互相独立的实现）
#    ① ModelSim : 编译 cartoon_96 + tb_cartoon_96，跑 8 行 1280 宽
#                 测试图案（x<640 暗灰 0x30 / x>=640 亮灰 0xC0），
#                 逐字导出 96bit 输出到 cartoon_out.txt
#    ② Python   : tools/check_cartoon.py 用**独立实现**的期望模型
#                 （Y=(77R+150G+29B)>>8、Q=(V&0xF0)|0x08、
#                   grad=max(3x3)-min(3x3)）逐像素核对
#
#  为什么这样做
#    P4 迭代中踩过两次"仿真全 PASS 但画面错"的坑：
#      · 第 1 版按字计址 ⇒ 每个字边界假边缘（3200/6370 平坦像素变黑）
#      · 第 2 版加了 passthru 直通 ⇒ 2628 个像素输出原色而非量化色
#    两次 TB 的结构断言（valid/吞吐）都是 PASS，问题只有逐像素核对能发现。
#    ⇒ 因此本脚本把"Python 独立逐像素核对"作为**唯一判据**。
#
#  用法：
#     pwsh -File .\sim\p4\run_p4_cartoon_check.ps1
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
if (-not $TbFile) { $TbFile = Join-Path $w 'sim\p4\tb_cartoon_96.v' }
if (-not $CheckPy) { $CheckPy = Join-Path $w 'tools\check_cartoon.py' }
if (-not $WorkDir) { $WorkDir = Join-Path $w '_stage\p4_sim' }

$ErrorActionPreference = 'Stop'
$vlib = Join-Path $ModelSimBin 'vlib.exe'
$vlog = Join-Path $ModelSimBin 'vlog.exe'
$vsim = Join-Path $ModelSimBin 'vsim.exe'
foreach ($t in @($vlib, $vlog, $vsim)) { if (-not (Test-Path $t)) { throw "not found: $t" } }

$hdl = Join-Path $ProjectDir 'user_source\hdl_source\isp'
$rtl = Join-Path $hdl 'cartoon_96.v'
if (-not (Test-Path $rtl)) { throw "not found: $rtl" }
if (-not (Test-Path $CheckPy)) { throw "not found: $CheckPy" }

if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
Push-Location $WorkDir

Write-Host ''
Write-Host '===== [1/2] ModelSim: compile + 3 scenarios ====='
& $vlib work | Out-Null
$c = & $vlog -work work $rtl $TbFile 2>&1
$c | Where-Object { $_ -match 'Error|Errors:|Compiling' } | ForEach-Object { Write-Host "  $_" }
if (($c | Select-String 'Errors: 0' -Quiet) -ne $true) { Pop-Location; throw 'compile failed' }

# 三个场景（每个都独立核对）
#   ① 基线        : 连续 8 行，I_tuser 以孤立脉冲给出（旧行为）
#   ② tuser_frame : I_tuser 与帧首有效字**同拍**（真机时序，走帧复位分支）
#   ③ gap         : 每行中间插 3 拍 I_tvalid 空洞（验证有空洞时仍对齐）
$scenarios = @(
    @{ name = 'baseline';    arg = @('+out=cartoon_out.txt') },
    @{ name = 'tuser_frame'; arg = @('+out=cartoon_out_tuser.txt', '+tuser_frame') },
    @{ name = 'gap';         arg = @('+out=cartoon_out_gap.txt', '+gap') }
)

$allRc = 0
foreach ($sc in $scenarios) {
    $t0 = Get-Date
    $a = $sc.arg
    $o = & $vsim -batch -lib work tb_cartoon_96 -do "run -all; quit -f" $a 2>&1
    $o | Where-Object { $_ -match '\[PASS\]|\[FAIL\]|\[OK\]|\[NG\]|PASS =|first valid|output valid' } |
        ForEach-Object { Write-Host ("  " + ($_ -replace '^\s*#\s?', '')) }
    Write-Host ("  [{0}] elapsed {1:N1}s" -f $sc.name, ((Get-Date) - $t0).TotalSeconds)

    $outFile = ($a | Where-Object { $_ -like '+out=*' }) -replace '^\+out=', ''
    if (-not (Test-Path $outFile)) { Pop-Location; throw "no output: $outFile" }

    Write-Host ''
    Write-Host ("===== [2/2] Python independent check -- scenario: {0} =====" -f $sc.name)
    $env:PYTHONIOENCODING = 'utf-8'
    & python $CheckPy --out (Join-Path $WorkDir $outFile) 2>&1 | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { $allRc = 1 }
    Write-Host ''
}

$rc = $allRc
Pop-Location
Write-Host ''
if ($rc -eq 0) { Write-Host 'RESULT: PASS  (cartoon behaviour matches independent model, all 3 scenarios)' }
else           { Write-Host "RESULT: FAIL  (exit $rc)" }
exit $rc
