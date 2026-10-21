# ============================================================
#  build_libs_vlog.ps1 — 用 vlog 编译 Anlogic PH1P 仿真原语库
#
#  为什么不用 `vsim -c -do ...`：
#     vsim **任何模式**都需要许可证（实测 exit 4），
#     但 vlib / vlog / vmap 不需要。所以库只能用 vlog 直接编。
#
#  用法：
#     powershell -ExecutionPolicy Bypass -File .\sim\build_libs_vlog.ps1
#     powershell -ExecutionPolicy Bypass -File .\sim\build_libs_vlog.ps1 -Force   # 重建
#
#  产物：sim\libs\anl_common   （AL_* 通用单元，实测 46 个）
#        sim\libs\anl_ph1p     （PH1P 原语，实测 1038 个）
#        sim\modelsim.ini      （库映射，供 vsim 用 -L 引用）
# ============================================================
[CmdletBinding()]
param(
    [string]$ModelRoot = 'F:\modelsim\modelsim_ase\win32aloem',
    [string]$TdRoot    = 'F:\al',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
# 本机 ModelSim 是 32 位 ASE（win32aloem），没有 win64 子目录；
# 若调用方仍传 F:\model 这种老路径，退回 PATH 上找 vlog。
$bin = $ModelRoot
if (-not (Test-Path (Join-Path $bin 'vlog.exe'))) {
    $c = Get-Command vlog.exe -ErrorAction SilentlyContinue
    if ($c) { $bin = Split-Path $c.Source -Parent } else { $bin = Join-Path $ModelRoot 'win64' }
}
$simRel = Join-Path $TdRoot    'sim_release'
$libs   = Join-Path $PSScriptRoot 'libs'

foreach ($p in @($bin, $simRel)) {
    if (-not (Test-Path $p)) { throw "路径不存在: $p" }
}

$vlib = Join-Path $bin 'vlib.exe'
$vlog = Join-Path $bin 'vlog.exe'
$vmap = Join-Path $bin 'vmap.exe'

if ($Force -and (Test-Path $libs)) {
    Write-Host "== -Force：删除已有库 $libs" -ForegroundColor Yellow
    Remove-Item $libs -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $libs | Out-Null
Push-Location $libs
try {
    # ------------------------------------------------ anl_common
    Write-Host "== 建库 anl_common" -ForegroundColor Cyan
    & $vlib anl_common | Out-Null
    $common = @()
    $common += Get-ChildItem (Join-Path $simRel 'common\*.v')            -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
    $common += Get-ChildItem (Join-Path $simRel 'common\apm\*.v')        -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
    Write-Host ("   编译 {0} 个文件 ..." -f $common.Count)
    $out = & $vlog -quiet -work anl_common @common 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "   !! vlog 返回 $LASTEXITCODE" -ForegroundColor Red
        $out | Where-Object { $_ -match 'Error|Failed' } | Select-Object -First 10 | ForEach-Object { Write-Host "      $_" }
    }
    $nC = (Get-ChildItem anl_common -Force -ErrorAction SilentlyContinue | Measure-Object).Count
    Write-Host ("   anl_common: {0} 个单元" -f $nC) -ForegroundColor Green

    # ------------------------------------------------ anl_ph1p
    Write-Host "== 建库 anl_ph1p" -ForegroundColor Cyan
    & $vlib anl_ph1p | Out-Null
    # 只编 .v；跳过 ph1p_phy_hxt_v*.sv(11/34MB) 与 ph1p_phy_pcie_v1.sv(24MB)
    # —— 本设计不用 HXT/PCIe，且是 SystemVerilog，编译极慢。
    $ph1p = Get-ChildItem (Join-Path $simRel 'ph1p\*.v') -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName }
    Write-Host ("   编译 {0} 个 .v 文件（~20 秒）..." -f $ph1p.Count)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $out2 = & $vlog -quiet -work anl_ph1p @ph1p 2>&1
    $rc = $LASTEXITCODE
    $sw.Stop()
    if ($rc -ne 0) {
        Write-Host "   !! vlog 返回 $rc" -ForegroundColor Red
        $out2 | Where-Object { $_ -match 'Error|Failed' } | Select-Object -First 10 | ForEach-Object { Write-Host "      $_" }
    }
    # protected region 的 Warning 是正常的（安路加密 IP）
    $warnN = ($out2 | Where-Object { $_ -match 'protected region' } | Measure-Object).Count
    if ($warnN -gt 0) { Write-Host ("   注：{0} 条 'protected region' 警告属正常（安路加密 IP）" -f $warnN) -ForegroundColor DarkGray }
    $nP = (Get-ChildItem anl_ph1p -Force -ErrorAction SilentlyContinue | Measure-Object).Count
    Write-Host ("   anl_ph1p: {0} 个单元，用时 {1:N0}s" -f $nP, $sw.Elapsed.TotalSeconds) -ForegroundColor Green

    # ------------------------------------------------ work
    Write-Host "== 建库 work（用户设计）" -ForegroundColor Cyan
    & $vlib work | Out-Null

    # ------------------------------------------------ 库映射
    # 生成一份 modelsim.ini，便于 vsim -L 引用时不必手工 vmap
    $ini = Join-Path $PSScriptRoot 'modelsim.ini'
    $content = @"
; 由 sim\build_libs_vlog.ps1 生成
[Library]
work       = `$MODEL_TECH/../work
std        = `$MODEL_TECH/../std
ieee       = `$MODEL_TECH/../ieee
vital2000  = `$MODEL_TECH/../vital2000
anl_common = $libs\anl_common
anl_ph1p   = $libs\anl_ph1p
"@
    Set-Content -Path $ini -Value $content -Encoding ASCII
    Write-Host "== 已写库映射: $ini" -ForegroundColor Green
}
finally { Pop-Location }

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host " 库编译完成。仿真命令（需要 vsim 许可证）：" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
Write-Host @"
  cd <工程>\sim
  vmap -c
  vlib work
  vlog -sv tb_top.v ../src/*.v
  vsim -voptargs="+acc" -t 1ps -L anl_common -L anl_ph1p work.tb_top
  run -all

（先跑 `sim\add_modelsim.ps1` 确认 vsim 许可证是否已就绪）
"@
