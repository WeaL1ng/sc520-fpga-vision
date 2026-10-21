# ============================================================
#  run_key_tb.ps1 -- 一键跑 key_mode_ctrl 功能仿真
#
#  用途：把"编译 + 仿真 + 判定"合成一条命令，便于每次改完 RTL 立即回归。
#
#  环境（2026-09-19 实测可用）：
#     **ModelSim ALTERA STARTER EDITION 10.3c**
#     F:\modelsim\modelsim_ase\win32aloem\
#     免费版，**不需要许可证**。
#
#  背景（避免走回头路）：
#     本机原先装的是 ModelSim SE-64 10.1c（F:\model），**它需要 Mentor 许可证**，
#     而本机没有任何许可证文件（无 LM_LICENSE_FILE、modelsim.ini 无 license 行、
#     全盘无 license.dat / *.lic / mgls*.dat），所以 vsim 报
#     "Unable to checkout a license" 并 exit 4。
#     现已换成 Altera Starter Edition —— 免费、无需许可证、10.3c，实测可跑仿真。
#
#  用法：
#     powershell -ExecutionPolicy Bypass -File .\sim\run_key_tb.ps1
# ============================================================
[CmdletBinding()]
param(
    [string]$ModelSimBin = 'F:\modelsim\modelsim_ase\win32aloem',
    [string]$TbDir       = ''
)

$ErrorActionPreference = 'Stop'

$vlib = Join-Path $ModelSimBin 'vlib.exe'
$vlog = Join-Path $ModelSimBin 'vlog.exe'
$vsim = Join-Path $ModelSimBin 'vsim.exe'
foreach ($p in @($vlib, $vlog, $vsim)) {
    if (-not (Test-Path $p)) { throw "缺少 $p  （ModelSim 是否已安装？见 README）" }
}

if (-not $TbDir) { $TbDir = Join-Path $PSScriptRoot 'tb' }
$dut = Join-Path $PSScriptRoot '..\rtl_vendor\anlogic_example\lab_ex4_all_features_SC500_720P\lab_ex4_all_features\user_source\hdl_source\key_mode_ctrl.v'
if (-not (Test-Path $dut)) { throw "找不到 DUT: $dut" }
$dut = (Resolve-Path $dut).Path

Write-Host '========================================================' -ForegroundColor Cyan
Write-Host ' key_mode_ctrl 功能仿真' -ForegroundColor Cyan
Write-Host '========================================================' -ForegroundColor Cyan
Write-Host " ModelSim : $ModelSimBin"
Write-Host " DUT      : $dut"

Push-Location $TbDir
try {
    # 每次重建 work，确保源改动生效
    if (Test-Path work) { Remove-Item work -Recurse -Force }

    Write-Host ''
    Write-Host '[1/3] vlib work' -ForegroundColor Yellow
    & $vlib work | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "vlib 失败" }

    Write-Host '[2/3] vlog 编译 DUT 与 TB' -ForegroundColor Yellow
    $o1 = & $vlog -quiet -work work $dut 2>&1
    if ($LASTEXITCODE -ne 0) { $o1 | Select-Object -First 15 | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }; throw "DUT 编译失败" }
    $o2 = & $vlog -quiet -work work 'tb_key_mode_ctrl.v' 2>&1
    if ($LASTEXITCODE -ne 0) { $o2 | Select-Object -First 15 | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }; throw "TB 编译失败" }

    Write-Host '[3/3] vsim 运行' -ForegroundColor Yellow
    Write-Host ''
    # 用 cmd 包装：vsim 会往 stderr 写，直接 2>&1 会被 PowerShell 当 NativeCommandError
    $out = & cmd.exe /c "`"$vsim`" -c -quiet -lib work tb_key_mode_ctrl -do `"run -all; quit -f`" 2>&1"
    $rc  = $LASTEXITCODE
    $out | ForEach-Object { Write-Host "  $_" }

    Write-Host ''
    $allPass = ($out | Where-Object { $_ -match '\*\*\* ALL TESTS PASSED \*\*\*' }).Count -gt 0
    $anyFail = ($out | Where-Object { $_ -match '\*\*\* THERE WERE' }).Count -gt 0

    if ($rc -eq 0 -and $allPass -and -not $anyFail) {
        Write-Host '========================================================' -ForegroundColor Green
        Write-Host ' 结果: 全部测试通过' -ForegroundColor Green
        Write-Host '========================================================' -ForegroundColor Green
        exit 0
    } else {
        Write-Host '========================================================' -ForegroundColor Red
        Write-Host ' 结果: 有失败项（见上面 FAIL 行）' -ForegroundColor Red
        Write-Host '========================================================' -ForegroundColor Red
        exit 1
    }
}
finally { Pop-Location }
