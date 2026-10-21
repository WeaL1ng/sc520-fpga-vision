# ============================================================
#  run_p3_latency_check.ps1 -- P3 延迟测量（按 DDR BANK 索引）验证，一键
#
#  为什么重写
#    P3 第一版的模块级 TB 8/8 全过，但**上板是错的**：屏上 LATENCY 在
#    0~10 ms 之间来回扫，算的其实是"采集帧内的相位"，不含帧缓冲那 2 帧。
#    根因是旧 TB 对集成的建模不对（假设显示域会用到"对应的"标签）。
#
#  本脚本跑 **两个场景**，每个都同时跑 DUT（新算法）和参考模型（P3 旧算法）：
#    ① 采集 10.00 ms / 显示 16.50 ms（与板上 VTC 实测一致）
#    ② 采集 16.70 ms / 显示 16.50 ms（帧率接近 ⇒ 旧方案"慢扫"）
#  判定：新方案恒在 [2P_c, 3P_c]（真实延迟）；
#        旧方案恒 < 2P_c（复现板上现象）。
#
#  用法：
#     powershell -ExecutionPolicy Bypass -File .\sim\p3\run_p3_latency_check.ps1
# ============================================================
[CmdletBinding()]
param(
    [string]$ProjectDir = '',
    [string]$ModelSimBin = 'F:\modelsim\modelsim_ase\win32aloem',
    [string]$TbFile = '',
    [string]$WorkDir = ''
)

$w = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
if (-not $ProjectDir) { $ProjectDir = Join-Path $w 'rtl_vendor\anlogic_example\lab_ex4_all_features_SC500_720P\lab_ex4_all_features' }
if (-not $TbFile) { $TbFile = Join-Path $w 'sim\p3\tb_frame_latency_bank.v' }
if (-not $WorkDir) { $WorkDir = Join-Path $w '_stage\p3_lat_sim' }

$ErrorActionPreference = 'Stop'
$vlib = Join-Path $ModelSimBin 'vlib.exe'
$vlog = Join-Path $ModelSimBin 'vlog.exe'
$vsim = Join-Path $ModelSimBin 'vsim.exe'
foreach ($t in @($vlib, $vlog, $vsim)) { if (-not (Test-Path $t)) { throw "not found: $t" } }

$rtl = Join-Path $ProjectDir 'user_source\hdl_source\frame_latency.v'
if (-not (Test-Path $rtl)) { throw "not found: $rtl" }

if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
Push-Location $WorkDir

Write-Host ''
Write-Host '===== [1/2] ModelSim: compile ====='
& $vlib work | Out-Null
$c = & $vlog -work work $rtl $TbFile 2>&1
$c | Where-Object { $_ -match 'Error|Errors:|Compiling' } | ForEach-Object { Write-Host "  $_" }
if (($c | Select-String 'Errors: 0' -Quiet) -ne $true) { Pop-Location; throw 'compile failed' }

$scenarios = @(
    @{ name = 'P_c=10.00ms / P_d=16.50ms'; arg = @('+pc=100', '+pd=165') },
    @{ name = 'P_c=16.70ms / P_d=16.50ms'; arg = @('+pc=167', '+pd=165') }
)

$allRc = 0
foreach ($sc in $scenarios) {
    Write-Host ''
    Write-Host ("===== [2/2] 场景: {0} =====" -f $sc.name)
    $a = $sc.arg
    $t0 = Get-Date
    $o = & $vsim -batch -lib work tb_frame_latency_bank -do "run -all; quit -f" $a 2>&1
    $o | Set-Content -Path (Join-Path $WorkDir ("sim_" + ($a -join '_') + ".log")) -Encoding UTF8
    $o | Where-Object { $_ -match '\[PASS\]|\[FAIL\]|\[OK\]|\[NG\]|PASS =|新方案|旧方案|出厂配置|真实延迟区间|P_c =|P_d =' } |
        ForEach-Object { Write-Host ("  " + ($_ -replace '^\s*#\s?', '').TrimEnd()) }
    Write-Host ("  elapsed {0:N1}s" -f ((Get-Date) - $t0).TotalSeconds)
    if ($o | Select-String '\[FAIL\]|\[NG\]' -Quiet) { $allRc = 1 }
}

Pop-Location
Write-Host ''
if ($allRc -eq 0) { Write-Host 'RESULT: PASS  (新算法测真实延迟；旧算法缺陷已在仿真中复现)' }
else              { Write-Host 'RESULT: FAIL' }
exit $allRc
