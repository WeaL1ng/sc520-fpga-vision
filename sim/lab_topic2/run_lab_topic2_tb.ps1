# ============================================================
#  run_lab_topic2_tb.ps1 -- 一键跑 lab_topic2_basic 的自检 TB
#
#  被测模块：
#     isp/gray_binary_96.v   灰度/二值化/反色   -> tb_gray_binary_96
#     key_ctrl.v             去抖/长短按        -> tb_key_ctrl
#
#  环境：ModelSim ALTERA STARTER EDITION 10.3c（免费，不需要许可证）
#        注意 ASE **没有 vopt.exe**，所以只能用 vlog + vsim，
#        不要用 vopt 相关脚本。
#
#  用法：
#     powershell -ExecutionPolicy Bypass -File .\sim\lab_topic2\run_lab_topic2_tb.ps1
#     powershell -ExecutionPolicy Bypass -File .\sim\lab_topic2\run_lab_topic2_tb.ps1 -Which gray
#     powershell -ExecutionPolicy Bypass -File .\sim\lab_topic2\run_lab_topic2_tb.ps1 -Which key
# ============================================================
[CmdletBinding()]
param(
    [ValidateSet('all', 'gray', 'key')]
    [string]$Which = 'all',

    [string]$ModelSimBin = 'F:\modelsim\modelsim_ase\win32aloem',

    [string]$ProjectDir = '',

    [string]$TbDir = '',

    [string]$WorkDir = ''
)

$w = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
if (-not $ProjectDir) { $ProjectDir = Join-Path $w 'rtl_vendor\anlogic_example\lab_topic2_basic\lab_topic2_basic' }
if (-not $TbDir) { $TbDir = Join-Path $w 'sim\lab_topic2' }
if (-not $WorkDir) { $WorkDir = Join-Path $w '_stage\lab_topic2_sim' }

$ErrorActionPreference = 'Stop'

$vlib = Join-Path $ModelSimBin 'vlib.exe'
$vlog = Join-Path $ModelSimBin 'vlog.exe'
$vsim = Join-Path $ModelSimBin 'vsim.exe'
foreach ($t in @($vlib, $vlog, $vsim)) {
    if (-not (Test-Path $t)) { throw "找不到 $t" }
}

$rtl = Join-Path $ProjectDir 'user_source\hdl_source'
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
Push-Location $WorkDir

# 刷新 work 库
if (Test-Path 'work') { Remove-Item 'work' -Recurse -Force }
& $vlib work | Out-Null

$cases = @()
if ($Which -eq 'all' -or $Which -eq 'gray') {
    $cases += [pscustomobject]@{
        Name = 'tb_gray_binary_96'
        Rtl  = @((Join-Path $rtl 'isp\gray_binary_96.v'))
        Tb   = (Join-Path $TbDir 'tb_gray_binary_96.v')
    }
}
if ($Which -eq 'all' -or $Which -eq 'key') {
    $cases += [pscustomobject]@{
        Name = 'tb_key_ctrl'
        Rtl  = @((Join-Path $rtl 'key_ctrl.v'))
        Tb   = (Join-Path $TbDir 'tb_key_ctrl.v')
    }
}

$totalErr = 0
foreach ($c in $cases) {
    Write-Host ''
    Write-Host "============================================================"
    Write-Host " 编译 + 运行 $($c.Name)"
    Write-Host "============================================================"

    # 每个 TB 用独立的 work 库目录避免互相覆盖：这里简单起见共用 work，
    # 但先清 work 再编，保证干净。
    if (Test-Path 'work') { Remove-Item 'work' -Recurse -Force }
    & $vlib work | Out-Null

    $files = @()
    foreach ($r in $c.Rtl) { $files += $r }
    $files += $c.Tb

    $o1 = & $vlog -work work @files 2>&1
    $o1 | Where-Object { $_ -match 'Errors:|Error|\*\*' } | ForEach-Object { Write-Host "  $_" }
    $compileErr = ($o1 | Select-String -Pattern 'Errors: 0' | Measure-Object).Count
    if ($compileErr -eq 0) {
        Write-Host "  [FAIL] 编译未通过"
        $totalErr++
        continue
    }

    $o2 = & $vsim -batch -lib work $c.Name -do "run -all; quit -f" 2>&1
    $o2 | Where-Object { $_ -match '^\s*#' } | ForEach-Object {
        Write-Host ("  " + ($_ -replace '^\s*#\s?', ''))
    }

    $pass = ($o2 | Select-String -Pattern '全部通过' | Measure-Object).Count
    $fail = ($o2 | Select-String -Pattern '\[FAIL\]' | Measure-Object).Count
    if ($pass -gt 0 -and $fail -eq 0) {
        Write-Host "  ==> $($c.Name) 通过"
    } else {
        Write-Host "  ==> $($c.Name) **失败**"
        $totalErr++
    }
}

Pop-Location
Write-Host ''
Write-Host "============================================================"
if ($totalErr -eq 0) {
    Write-Host " 全部 TB 通过"
} else {
    Write-Host " 有 $totalErr 个 TB 失败"
}
Write-Host "============================================================"
exit $totalErr
