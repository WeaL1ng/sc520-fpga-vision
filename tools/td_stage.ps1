# td_stage.ps1 - 在 10 分钟工具超时窗口内分段跑 TD 流程
#
# 背景：本会话的 pwsh 工具单次调用上限为 600 秒，且子进程无法脱离作业对象，
#       因此必须把 TD 流程拆成 <10 分钟的若干段。TD 的流程脚本天然支持这种拆法：
#       每段结束时它会 export_db 出该段的 .db，下一段用 `import_db` 接着跑。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File td_stage.ps1 -Stage syn_rtl
#   powershell -ExecutionPolicy Bypass -File td_stage.ps1 -Stage syn_gate
#   powershell -ExecutionPolicy Bypass -File td_stage.ps1 -Stage phy
#
# 段定义（依据各 run 目录 settings.cfg 的 start_step / end_step）：
#   syn_rtl   : read_design -> opt_rtl        约 6.8 分钟（opt_rtl 是大头，382s）
#   syn_gate  : opt_gate                      约 3.5 分钟
#   phy       : opt_place -> bitgen           约 6.5 分钟

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('syn_rtl', 'syn_rtl2', 'syn_gate', 'phy', 'phy_place', 'phy_route')]
    [string]$Stage,

    # 工程根目录（含 td_project/ 与 user_source/）。
    # 默认是原 lab_ex4；做 P1b 等实验时务必用 -ProjectRoot 指向副本，
    # 否则会污染冻结的原目录（这是踩过的坑，见 doc/analysis/P1b设计-* §5）。
    [string]$ProjectRoot = ''
)

$w = (Split-Path -Parent $PSScriptRoot)
if (-not $ProjectRoot) { $ProjectRoot = Join-Path $w 'rtl_vendor\anlogic_example\lab_ex4_all_features_SC500_720P\lab_ex4_all_features' }

$ErrorActionPreference = 'Stop'
$lab = $ProjectRoot
if (-not (Test-Path "$lab\td_project\camera_to_dsi_display.al")) {
    throw "ProjectRoot 无效（找不到 $lab\td_project\camera_to_dsi_display.al）"
}
Write-Host "  ProjectRoot = $lab"
$syncfg = "$lab\td_project\camera_to_dsi_display_Runs\syn_1\settings.cfg"
$phycfg = "$lab\td_project\camera_to_dsi_display_Runs\phy_1\settings.cfg"

function Set-FlowStep {
    param([string]$Cfg, [string]$Start, [string]$End)
    # 备份一次（不覆盖已有备份）
    $bak = "$Cfg.orig"
    if (-not (Test-Path $bak)) { Copy-Item $Cfg $bak -Force }
    $lines = Get-Content $Cfg
    $lines = $lines | ForEach-Object {
        if ($_ -match '^\s*set\s+start_step\s') { "set start_step $Start" }
        elseif ($_ -match '^\s*set\s+end_step\s') { "set end_step $End" }
        else { $_ }
    }
    Set-Content -Path $Cfg -Value $lines -Encoding ASCII
    "  $([IO.Path]::GetFileName((Split-Path $Cfg -Parent)))  start_step=$Start  end_step=$End"
}

switch ($Stage) {
    'syn_rtl'  { $dir = "$lab\td_project\camera_to_dsi_display_Runs\syn_1"; Set-FlowStep $syncfg 'read_design' 'opt_rtl' }
    'syn_rtl2' { $dir = "$lab\td_project\camera_to_dsi_display_Runs\syn_1"; Set-FlowStep $syncfg 'opt_rtl'     'opt_rtl' }
    'syn_gate' { $dir = "$lab\td_project\camera_to_dsi_display_Runs\syn_1"; Set-FlowStep $syncfg 'opt_gate'    'opt_gate' }
    'phy'       { $dir = "$lab\td_project\camera_to_dsi_display_Runs\phy_1"; Set-FlowStep $phycfg 'opt_place' 'bitgen' }
    'phy_place' { $dir = "$lab\td_project\camera_to_dsi_display_Runs\phy_1"; Set-FlowStep $phycfg 'opt_place' 'opt_place' }
    'phy_route' { $dir = "$lab\td_project\camera_to_dsi_display_Runs\phy_1"; Set-FlowStep $phycfg 'opt_route' 'bitgen' }
}

"=== 段 [$Stage] ==="
"  工作目录: $dir"
"  开始     : $(Get-Date -Format HH:mm:ss)"

# 阶段标记：本段之前的标记保留（证明前置步骤已完成），只清理本段自己的标记
$ownMarks = switch ($Stage) {
    'syn_rtl'  { @('.read_design.begin.f', '.read_design.end.f', '.opt_rtl.begin.f', '.opt_rtl.end.f') }
    'syn_rtl2' { @('.opt_rtl.begin.f', '.opt_rtl.end.f', '.opt_rtl.error.f') }
    'syn_gate' { @('.opt_gate.begin.f', '.opt_gate.end.f', '.opt_gate.error.f') }
    'phy'       { @('.opt_place.begin.f', '.opt_place.end.f', '.opt_route.begin.f', '.opt_route.end.f', '.bitgen.begin.f', '.bitgen.end.f', '.opt_place.error.f', '.opt_route.error.f', '.bitgen.error.f') }
    'phy_place' { @('.opt_place.begin.f', '.opt_place.end.f', '.opt_place.error.f') }
    'phy_route' { @('.opt_route.begin.f', '.opt_route.end.f', '.bitgen.begin.f', '.bitgen.end.f', '.opt_route.error.f', '.bitgen.error.f') }
}
foreach ($m in $ownMarks) { if (Test-Path "$dir\$m") { Remove-Item "$dir\$m" -Force } }
if (Test-Path "$dir\.stop.f") { Remove-Item "$dir\.stop.f" -Force }

$log = (Join-Path (Split-Path -Parent $PSScriptRoot) "_stage\lab4_$Stage`_$(Get-Date -Format HHmmss).log")
$t0 = Get-Date
Push-Location $dir
try {
    & 'F:\al\bin\td_commands_prompt.exe' 'camera_to_dsi_display.tcl' 2>&1 |
        Tee-Object -FilePath $log | Select-Object -Last 4
    $rc = $LASTEXITCODE
} finally {
    Pop-Location
}
$el = [math]::Round(((Get-Date) - $t0).TotalMinutes, 2)

"`n=== 段 [$Stage] 结束 ==="
"  退出码   : $rc"
"  耗时     : $el 分钟"
"  日志     : $log"

"`n--- 本目录阶段标记 ---"
Get-ChildItem $dir -Filter '.*.f' -Force | Sort-Object Name |
    ForEach-Object { '  {0,-24} {1,4}B  {2}' -f $_.Name, $_.Length, $_.LastWriteTime.ToString('HH:mm:ss') }

"`n--- 关键 db 产物 ---"
Get-ChildItem $dir -File | Where-Object { $_.Extension -in '.db', '.area', '.timing', '.ts' } |
    Sort-Object LastWriteTime |
    ForEach-Object { '  {0}  {1,-46} {2,10}' -f $_.LastWriteTime.ToString('HH:mm:ss'), $_.Name, $_.Length }

"`n--- 日志中的错误 ---"
$errs = Select-String -Path $log -Pattern 'ERROR|FATAL|abort' -ErrorAction SilentlyContinue
if ($errs) { $errs | Select-Object -First 10 | ForEach-Object { '  L{0}: {1}' -f $_.LineNumber, $_.Line.Trim() } } else { '  无' }
