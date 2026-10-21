# ============================================================
#  compile_check.ps1 -- 用 ModelSim vlog 做纯语法/编译检查
#
#  为什么有用：
#     `vlog` 能编译并报告语法错误、模块未定义、端口不存在，
#     但**不要求所有子模块都齐全**（未定义的模块只在 elaboration 时才报）。
#     所以它非常适合在整合过程中"每改一个文件就查一次"，
#     比跑一次完整 P&R（约 10 分钟）快得多（几秒）。
#
#  环境：ModelSim ALTERA STARTER EDITION 10.3c（免费，不需要许可证）
#        F:\modelsim\modelsim_ase\win32aloem
#
#  用法：
#     powershell -ExecutionPolicy Bypass -File .\sim\compile_check.ps1 `
#         -Files "a.v,b.v,c.v"
#     powershell -ExecutionPolicy Bypass -File .\sim\compile_check.ps1 `
#         -RtlRoot <工程 user_source> -AllHdl
# ============================================================
[CmdletBinding()]
param(
    [string]$Files    = '',
    [string]$RtlRoot  = '',
    [switch]$AllHdl,
    [string]$Include  = '',
    [string]$ModelSimBin = 'F:\modelsim\modelsim_ase\win32aloem',
    [string]$WorkDir  = ''
)

$ErrorActionPreference = 'Stop'
$vlib = Join-Path $ModelSimBin 'vlib.exe'
$vlog = Join-Path $ModelSimBin 'vlog.exe'
foreach ($p in @($vlib,$vlog)) { if (-not (Test-Path $p)) { throw "缺少 $p" } }

if (-not $WorkDir) { $WorkDir = Join-Path $PSScriptRoot 'ccheck' }
if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null }
$WorkDir = (Resolve-Path $WorkDir).Path

# 收集文件
$list = @()
if ($Files) {
    foreach ($f in ($Files -split ',')) { $f = $f.Trim(); if ($f) { $list += (Resolve-Path $f).Path } }
}
if ($AllHdl) {
    if (-not $RtlRoot) { throw "-AllHdl 需要 -RtlRoot" }
    $root = (Resolve-Path $RtlRoot).Path
    Get-ChildItem $root -Recurse -File -Include *.v,*.sv |
        Where-Object { $_.Name -notmatch '\.enc\.' } |
        ForEach-Object { $list += $_.FullName }
}
if ($list.Count -eq 0) { throw "没有要编译的文件" }

Write-Host "== 待编译 $($list.Count) 个文件"
Write-Host "== 工作库   $WorkDir"

Push-Location $WorkDir
try {
    if (Test-Path work) { Remove-Item work -Recurse -Force }
    & $vlib work | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "vlib 失败" }

    $args = @('-quiet','-work','work')
    if ($Include) { foreach ($i in ($Include -split ',')) { $i=$i.Trim(); if ($i) { $args += @('+incdir+' + (Resolve-Path $i).Path) } } }
    $args += $list

    $o = & $vlog @args 2>&1
    $rc = $LASTEXITCODE

    $errs = @($o | Where-Object { $_ -match '\*\* Error' })
    $warns= @($o | Where-Object { $_ -match '\*\* Warning' })

    Write-Host ''
    Write-Host '============ vlog 编译检查结果 ============' -ForegroundColor Green
    Write-Host ("  退出码  : {0}" -f $rc)
    Write-Host ("  Error   : {0}" -f $errs.Count)
    Write-Host ("  Warning : {0}" -f $warns.Count)
    if ($errs.Count -gt 0) {
        Write-Host '  --- Error ---' -ForegroundColor Red
        $errs | Select-Object -First 25 | ForEach-Object { Write-Host "    $_" }
    }
    if ($warns.Count -gt 0) {
        Write-Host '  --- Warning 去重（前 15）---' -ForegroundColor Yellow
        $warns | ForEach-Object { $_ -replace '^\*\* Warning:\s*','' } | Sort-Object -Unique |
            Select-Object -First 15 | ForEach-Object { Write-Host "    $_" }
    }
    Write-Host ''
    if ($rc -eq 0) { Write-Host '  [PASS] 编译通过（语法/模块引用无错）' -ForegroundColor Green }
    else           { Write-Host '  [FAIL] 编译有错' -ForegroundColor Red }
    Write-Host '==========================================' -ForegroundColor Green
    exit $(if ($rc -eq 0) { 0 } else { 1 })
}
finally { Pop-Location }
