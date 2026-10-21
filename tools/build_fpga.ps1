# ============================================================
#  build_fpga.ps1 -- 一键跑完 TD 综合 + P&R + bitgen（命令行）
#
#  为什么需要它
#    单次 pwsh 工具调用有 600s 上限，而全流程约 10~13 分钟。
#    本脚本把"改 settings.cfg → 跑 syn → 跑 phy → 汇总报告"固化下来，
#    避免每次手工改 settings.cfg（改错 start_step 会静默复用旧 db，
#    表现为"改了 RTL 但时序/面积完全没变"——这个坑很隐蔽）。
#
#  ⚠ 三条 TD 命令行铁律（实测，缺一不可）
#    1. `td_commands_prompt.exe` 非 Unicode 安全 ⇒ TD 安装路径与工程路径
#       都必须纯 ASCII（本机 TD 在 `F:\al`），Tcl 脚本路径一律用 `/`。
#    2. `syn_1/settings.cfg` 若出现 `set sp 1`，`read_adc` 会在 elaborate
#       之前执行 ⇒ `USR-8128 CRITICAL-WARNING`。**`sp` 只能写在 phy_1**。
#    3. 想真正重综合必须让 `start_step = read_design`；若留在 `opt_gate`，
#       TD 会直接 import 旧 db，RTL 改动完全不生效。
#
#  用法：
#     pwsh -File .\tools\build_fpga.ps1                 # 全流程（syn + phy）
#     pwsh -File .\tools\build_fpga.ps1 -Stage syn      # 只跑综合
#     pwsh -File .\tools\build_fpga.ps1 -Stage phy      # 只跑 P&R
# ============================================================
[CmdletBinding()]
param(
    [string]$ProjectRoot = '',
    [string]$TdExe       = 'F:\al\bin\td_commands_prompt.exe',
    [string]$FlowTcl     = 'F:/al/scripts/DefaultFlow.tcl',
    [ValidateSet('all', 'syn', 'phy')]
    [string]$Stage       = 'all',
    [string]$LogDir = ''
)

$w = (Split-Path -Parent $PSScriptRoot)
if (-not $ProjectRoot) { $ProjectRoot = Join-Path $w 'rtl_vendor\anlogic_example\lab_ex4_all_features_SC500_720P\lab_ex4_all_features' }
if (-not $LogDir) { $LogDir = Join-Path $w '_stage\build_logs' }

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $TdExe)) { throw "not found: $TdExe" }
if (-not (Test-Path $FlowTcl)) { throw "not found: $FlowTcl" }

$runs = Join-Path $ProjectRoot 'td_project\camera_to_dsi_display_Runs'
$syn  = Join-Path $runs 'syn_1'
$phy  = Join-Path $runs 'phy_1'
foreach ($d in @($syn, $phy)) { if (-not (Test-Path $d)) { throw "not found: $d" } }

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

function Set-CfgValue {
    param([string]$File, [string]$Key, [string]$Value)
    $lines = [System.IO.File]::ReadAllLines($File)
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^\s*set\s+$([regex]::Escape($Key))\s") {
            $lines[$i] = "set $Key $Value"; $found = $true
        }
    }
    if (-not $found) { throw "key 'set $Key' not found in $File" }
    [System.IO.File]::WriteAllLines($File, $lines)
}

function Get-CfgValue {
    param([string]$File, [string]$Key)
    foreach ($l in [System.IO.File]::ReadAllLines($File)) {
        if ($l -match "^\s*set\s+$([regex]::Escape($Key))\s+(.+?)\s*$") { return $Matches[1] }
    }
    return $null
}

function Run-Stage {
    param([string]$Name, [string]$Dir, [string]$Cfg, [string]$Log)
    Write-Host ''
    Write-Host ("===== TD stage: {0} =====" -f $Name)
    Write-Host ("  dir  : {0}" -f $Dir)
    Write-Host ("  cfg  : start={0} end={1} sp={2}" -f `
        (Get-CfgValue $Cfg 'start_step'), (Get-CfgValue $Cfg 'end_step'), (Get-CfgValue $Cfg 'sp'))
    Write-Host ("  log  : {0}" -f $Log)
    $t0 = Get-Date
    Push-Location $Dir
    try {
        & $TdExe $FlowTcl 2>&1 | Tee-Object -FilePath $Log
        $rc = $LASTEXITCODE
    } finally { Pop-Location }
    $el = ((Get-Date) - $t0).TotalSeconds
    Write-Host ("  [{0}] exit={1}  elapsed {2:N0}s" -f $Name, $rc, $el)

    # ⚠ TD 命令行**可能 exit 0 但实际失败** ⇒ 必须看 step 标记文件与日志
    foreach ($s in @('read_design', 'opt_rtl', 'opt_gate', 'opt_place', 'opt_route', 'bitgen')) {
        if (Test-Path (Join-Path $Dir ".$s.error.f")) { throw "[$Name] step FAILED: $s (see $Log)" }
    }
    if ((Select-String -Path $Log -Pattern 'USR-\d+ ERROR|ERROR:' -Quiet)) {
        Write-Host "  [warn] log contains ERROR lines -- check $Log"
    }
    return $el
}

# ---------------------------------------------------------------- 综合
if ($Stage -in @('all', 'syn')) {
    $cfg = Join-Path $syn 'settings.cfg'
    $env:ALRUN = $null
    # 清掉上一轮的 step 标记，否则 step_begin/end 文件会误导判断
    Get-ChildItem $syn -Filter '.*.f' -Force -ErrorAction SilentlyContinue | Remove-Item -Force
    Set-CfgValue $cfg 'start_step' 'read_design'
    Set-CfgValue $cfg 'end_step'   'opt_gate'
    if ((Get-CfgValue $cfg 'sp')) { throw "syn_1/settings.cfg must NOT contain 'set sp' (USR-8128)" }
    Run-Stage -Name 'syn' -Dir $syn -Cfg $cfg -Log (Join-Path $LogDir "syn_$stamp.log") | Out-Null
}

# ---------------------------------------------------------------- P&R
if ($Stage -in @('all', 'phy')) {
    $cfg = Join-Path $phy 'settings.cfg'
    Get-ChildItem $phy -Filter '.*.f' -Force -ErrorAction SilentlyContinue | Remove-Item -Force
    Set-CfgValue $cfg 'start_step' 'opt_place'
    Set-CfgValue $cfg 'end_step'   'bitgen'
    Run-Stage -Name 'phy' -Dir $phy -Cfg $cfg -Log (Join-Path $LogDir "phy_$stamp.log") | Out-Null
}

# ---------------------------------------------------------------- 汇总
Write-Host ''
Write-Host '===== artifacts ====='
$bit = Join-Path $phy 'camera_to_dsi_display.bit'
$rep = @(
    @{ n = 'gate.area';   p = Join-Path $syn 'camera_to_dsi_display_gate.area' },
    @{ n = 'gate.timing'; p = Join-Path $syn 'camera_to_dsi_display_gate.timing' },
    @{ n = 'pr.timing';   p = Join-Path $phy 'camera_to_dsi_display_pr.timing' },
    @{ n = 'phy.area';    p = Join-Path $phy 'camera_to_dsi_display_phy.area' },
    @{ n = 'chk.timing';  p = Join-Path $phy 'camera_to_dsi_display_chk.timing' }
)
foreach ($r in $rep) {
    if (Test-Path $r.p) {
        Write-Host ("  {0,-12} {1,10:N0} B  {2}" -f $r.n, (Get-Item $r.p).Length, (Get-Item $r.p).LastWriteTime)
    } else { Write-Host ("  {0,-12} MISSING" -f $r.n) }
}
if (Test-Path $bit) {
    $bi = Get-Item $bit
    Write-Host ("  bitstream    {0,10:N0} B  {1}" -f $bi.Length, $bi.LastWriteTime)
} else { Write-Host '  bitstream    MISSING' }

Write-Host ''
Write-Host '下一步：python tools\verify_td_reports.py   # 独立解析报告并判达标'
exit 0
