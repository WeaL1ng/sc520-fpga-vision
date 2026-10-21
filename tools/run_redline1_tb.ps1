# ============================================================================
#  run_redline1_tb.ps1 --- 红线1（gray_binary_96 取代 Sobel）功能验证
#
#  纯 RTL，无供应商原语，不需要 glbl。
# ============================================================================
param(
    [string]$ProjectRoot = ''
)

$w = (Split-Path -Parent $PSScriptRoot)
if (-not $ProjectRoot) { $ProjectRoot = Join-Path $w 'rtl_vendor\anlogic_example\lab_ex4_all_features_SC500_720P\lab_ex4_all_features' }
$ErrorActionPreference = "Stop"
$w   = (Split-Path -Parent $PSScriptRoot)
$dir = "$w\_stage\redline1_sim"
$vlog = "F:\modelsim\modelsim_ase\win32aloem\vlog.exe"
$vsim = "F:\modelsim\modelsim_ase\win32aloem\vsim.exe"
$vlib = "F:\modelsim\modelsim_ase\win32aloem\vlib.exe"

if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Set-Location $dir

& $vlib work | Out-Null
$srcs = @(
    "$ProjectRoot/user_source/hdl_source/isp/gray_binary_96.v",
    "$w/sim/redline1/tb_gray_binary_96.v"
)
& $vlog -work work @srcs 2>&1 | Tee-Object -FilePath "$dir\compile.log" | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "编译失败"; exit 1 }

& $vsim -batch -lib work tb_gray_binary_96 -do "run -all; quit -f" 2>&1 |
    Tee-Object -FilePath "$dir\sim.log" | Out-Null

Select-String -Path "$dir\sim.log" -Pattern '\[PASS\]|\[FAIL\]|PASS =|\[OK\]|\[NG\]|tb_gray' |
    ForEach-Object { "  " + ($_.Line -replace '^#\s*','').TrimEnd() }
Write-Host ""
Write-Host "日志: $dir\sim.log"
