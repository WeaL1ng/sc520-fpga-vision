<#
.SYNOPSIS
  run_regression.ps1 —— 重跑 TD 的 P&R 流程，抽取关键指标，追加到趋势表。

.DESCRIPTION
  本方案的核心纪律是"每加/改一个模块就重跑一次 P&R，并记录 slices 与各时钟域裕量"。
  这个脚本把那件事变成一条命令。

  它做三件事：
    1. 调用 TD 的 DefaultFlow.tcl 重跑 syn + place + route + bitgen
    2. 从 route.qor / camera_to_dsi_display_phy.area / final_timing.rpt 里抽取指标
    3. 追加（或更新）一行到 <ProjectRoot>\doc\regression\trend.csv，并打印对比

.PARAMETER ProjectRoot
  工程根目录，即含 td_project 的那一层，例如：
    C:\work\saiti2\lab4

.PARAMETER Tag
  本次改动的一行说明（写入 CSV 的 note 列），例如 "P1 logo->ERAM"

.PARAMETER Stage
  阶段标记（P0/P1/...），可空

.PARAMETER TdRoot
  TD 安装目录，默认从 PATH 上的 td_commands_prompt.exe 推断，否则 F:\al（旧路径 F:\安路 作为回退）

.PARAMETER SkipBuild
  只解析已有报告，不重跑流程（快速看当前状态）

.EXAMPLE
  .\run_regression.ps1 -ProjectRoot C:\work\saiti2\lab4 -Tag "P1 logo->ERAM" -Stage P1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [string]$Tag = "",
    [string]$Stage = "",
    [string]$TdRoot = "",
    [switch]$SkipBuild,
    # 每个关键域要求的"最小裕量 (ns)"，键名是时钟名的一部分（模糊匹配）。
    # 不传时只做"无负裕量 + slices<=80% + 无违例"的硬检查，其余为警告。
    # 阶段门禁示例：
    #   -Targets @{ HDMI_PIXEL_CLK = 1.5; usr_clk = 1.5; MIPI_RX_BYTE_CLK = 3.0 }
    [hashtable]$Targets = @{},
    [double]$WarnSlack = 0.5
)

$ErrorActionPreference = 'Stop'

# 真正驱动数据通路的关键域。PHY 内部时钟（ddr_clk/ctl_clk/ref_clk/tif_c16_in/
# io_clk_pad_p/mipi_rx_ck_pad）SWNS 恒等于其周期，不参与门禁判断。
$CriticalClockPatterns = @(
    'MIPI_RX_BYTE_CLK',
    'HDMI_PIXEL_CLK',
    'HDMI_SERIAL_CLK',
    'usr_clk',
    'sys_clk_50m',
    'pll_clk_24m',
    'pll_clk_100m',
    'ALGO_CLK'          # 若将来新增算法域，按此命名即可自动纳入
)
function Test-CriticalClock {
    param([string]$Name)
    if (-not $Name) { return $false }
    foreach ($p in $CriticalClockPatterns) { if ($Name -like "*$p*") { return $true } }
    return $false
}

# ---------------------------------------------------------------- 定位路径

if (-not $TdRoot) {
    $cmd = Get-Command td_commands_prompt.exe -ErrorAction SilentlyContinue
    if ($cmd) { $TdRoot = Split-Path (Split-Path $cmd.Source -Parent) -Parent }
    elseif (Test-Path 'F:\al') { $TdRoot = 'F:\al' }
    elseif (Test-Path 'F:\安路') { $TdRoot = 'F:\安路' }
    else { throw "找不到 TD 安装目录，请用 -TdRoot 指定" }
}
$TdPrompt = Join-Path $TdRoot 'bin\td_commands_prompt.exe'
if (-not (Test-Path $TdPrompt)) { throw "缺少 $TdPrompt" }

# DefaultFlow.tcl 的位置随 TD 版本不同：<root>\scripts\ 或 <root>\doc\scripts\
$FlowTcl = $null
foreach ($cand in @('scripts\DefaultFlow.tcl', 'doc\scripts\DefaultFlow.tcl',
                    'bin\scripts\DefaultFlow.tcl')) {
    $p = Join-Path $TdRoot $cand
    if (Test-Path $p) { $FlowTcl = $p; break }
}
if (-not $FlowTcl) {
    $found = Get-ChildItem $TdRoot -Recurse -File -Filter 'DefaultFlow.tcl' -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if ($found) { $FlowTcl = $found.FullName }
}
if (-not $FlowTcl) { throw "在 $TdRoot 下找不到 DefaultFlow.tcl" }
Write-Host "== TD    : $TdRoot"
Write-Host "== Flow  : $FlowTcl"

$RunRoot = Join-Path $ProjectRoot 'td_project'
if (-not (Test-Path $RunRoot)) { throw "找不到 $RunRoot" }

# 找 phy 运行目录（通常是 *_Runs\phy_1）
$phyDir = Get-ChildItem $RunRoot -Directory -Recurse -Filter 'phy_1' -ErrorAction SilentlyContinue |
          Select-Object -First 1
if (-not $phyDir) { throw "在 $RunRoot 下找不到 phy_1 运行目录" }
$phy = $phyDir.FullName
Write-Host "== 工程 : $ProjectRoot"
Write-Host "== 运行 : $phy"

# ---------------------------------------------------------------- 重跑流程

if (-not $SkipBuild) {
    Write-Host "== 重跑 TD 流程（syn + place + route + bitgen）..." -ForegroundColor Cyan
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Push-Location $phy
    try {
        & $TdPrompt $FlowTcl 2>&1 | Tee-Object -FilePath (Join-Path $phy 'regression_run.log') |
            Select-Object -Last 15
    } finally { Pop-Location }
    $sw.Stop()
    Write-Host ("== 流程结束，用时 {0:N1} 分钟" -f $sw.Elapsed.TotalMinutes)
}

# ---------------------------------------------------------------- 抽取指标

function Get-FirstMatch {
    param([string]$Path, [string]$Pattern, [int]$Group = 1)
    if (-not (Test-Path $Path)) { return $null }
    $m = Select-String -Path $Path -Pattern $Pattern -ErrorAction SilentlyContinue |
         Select-Object -First 1
    if ($m -and $m.Matches.Count -gt 0) { return $m.Matches[0].Groups[$Group].Value }
    return $null
}

$qor  = Join-Path $phy 'route.qor'
$area = Join-Path $phy 'camera_to_dsi_display_phy.area'
$tim  = Join-Path $phy 'final_timing.rpt'

$row = [ordered]@{
    time       = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    stage      = $Stage
    tag        = $Tag
    setup_wns_ps = Get-FirstMatch $qor 'Setup WNS\s*\|\s*(\d+)'
    hold_wns_ps  = Get-FirstMatch $qor 'Hold WNS\s*\|\s*(\d+)'
    viol_sep     = Get-FirstMatch $qor 'Num of violated S-EP\s*\|\s*(\d+)'
    slices       = Get-FirstMatch $qor '#slices\s*\|\s*(\d+)'
    slices_pct   = Get-FirstMatch $qor 'slices percentage\s*\|\s*([\d\.]+)'
    rams         = Get-FirstMatch $qor '#RAMs\s*\|\s*(\d+)'
    dsps         = Get-FirstMatch $qor '#DSPs\s*\|\s*(\d+)'
    lut6         = Get-FirstMatch $area '#lut6\s+(\d+)'
    lut6_pct     = Get-FirstMatch $area '#lut6\s+\d+\s+out of\s+\d+\s+([\d\.]+)%'
    regs         = Get-FirstMatch $area '#slice reg\s+(\d+)'
    regs_pct     = Get-FirstMatch $area '#slice reg\s+\d+\s+out of\s+\d+\s+([\d\.]+)%'
    eram         = Get-FirstMatch $area '#eram\s+(\d+)'
    wirelen      = Get-FirstMatch $qor 'Wire length\s*\|\s*(\d+)'
}

# 各时钟域的 SWNS（最差裕量，ns）+ Fmax（MHz）
$clockRows = @()
if (Test-Path $tim) {
    $txt = Get-Content $tim
    # Clock Summary 表： Name Type Rise Fall C-Period C-Freq R-Period R-Freq SWNS STNS HWNS HTNS ...
    $inTable = $false
    foreach ($line in $txt) {
        if ($line -match '^\s*Name\s+Type\s+Rise') { $inTable = $true; continue }
        if ($inTable) {
            if ($line -match '^\s*clk(\d+)\s+(\S.*)$') {
                # 列顺序: clk | Type | Rise | Fall | C-Period | C-Freq | R-Period | R-Freq | SWNS | STNS | HWNS | HTNS | ...
                if ($line -match '^\s*(clk\d+)\s+(.+?)\s{2,}([\d\.]+)\s+([\d\.]+)\s+([\d\.]+)\s+([\d\.]+)\s+([\d\.]+)\s+([\d\.]+)\s+([\d\.]+)\s+([\d\.]+)\s+([\d\.]+)\s+([\d\.]+)\s+([\d\.]+)') {
                    $clockRows += [pscustomobject]@{
                        clock  = $Matches[1]
                        c_freq = [double]$Matches[6]   # C-Freq  (约束频率 MHz)
                        fmax   = [double]$Matches[8]   # R-Freq  (实测 Fmax MHz)
                        swns   = [double]$Matches[9]   # SWNS    (最差裕量 ns)
                    }
                }
            }
            elseif ($line -match '^\s*-\s*$' -or $line -match '^\s*Notes') { $inTable = $false }
        }
    }
    # 名称在上一段 Clock Summary 的 “Clock-Id: C-Freq Fanout Clock-Name” 里
    $names = @{}
    foreach ($line in $txt) {
        if ($line -match '^\s*(clk\d+):\s+([\d\.]+)\s+(\d+)\s+(\S+)\s*$') {
            $names[$Matches[1]] = $Matches[4]
        }
    }
    foreach ($c in $clockRows) { $c | Add-Member -NotePropertyName name -NotePropertyValue ($names[$c.clock]) -Force }
}

# ---------------------------------------------------------------- 写入趋势表

$outDir = Join-Path $ProjectRoot 'doc\regression'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$csv = Join-Path $outDir 'trend.csv'

$obj = [pscustomobject]$row
if (Test-Path $csv) {
    $prev = Import-Csv $csv | Select-Object -Last 1
    $obj | Export-Csv -Path $csv -Append -NoTypeInformation -Encoding UTF8
} else {
    $prev = $null
    $obj | Export-Csv -Path $csv -NoTypeInformation -Encoding UTF8
}

# 每个域的裕量也单独存一份，便于画曲线
$cw = Join-Path $outDir 'clock_slack.csv'
$clockRows | Where-Object { $_.name } | ForEach-Object {
    [pscustomobject]@{
        time  = (Get-Date -Format 'yyyy-MM-dd HH:mm')
        stage = $Stage
        tag   = $Tag
        clock = $_.name
        freq  = $_.c_freq
        fmax  = $_.fmax
        swns  = $_.swns
    }
} | Export-Csv -Path $cw -Append -NoTypeInformation -Encoding UTF8

# ---------------------------------------------------------------- 打印

Write-Host ""
Write-Host "==================== 本次 P&R 结果 ====================" -ForegroundColor Green
$row.GetEnumerator() | Where-Object { $_.Value } |
    ForEach-Object { Write-Host ("{0,-14} : {1}" -f $_.Key, $_.Value) }

if ($clockRows.Count -gt 0) {
    Write-Host ""
    Write-Host "域裕量 (按 SWNS 升序；Fmax 需 >= 约束频率):"
    $clockRows | Where-Object { $_.name } | Sort-Object swns |
        ForEach-Object {
            $ratio = if ($_.c_freq -gt 0) { $_.fmax / $_.c_freq } else { 0 }
            $crit = Test-CriticalClock $_.name
            $flag = ''
            if ($_.swns -lt 0) { $flag = '  <== 负裕量!!!' }
            elseif ($crit -and $_.swns -lt 0.5) { $flag = '  <== 关键域警戒线以下' }
            elseif ($crit) { $flag = '  [关键域]' }
            Write-Host ("  {0,-24} 约束 {1,8:N3} MHz  Fmax {2,8:N3} MHz  x{3,5:N2}  SWNS {4,7:N3} ns{5}" -f `
                $_.name, $_.c_freq, $_.fmax, $ratio, $_.swns, $flag)
        }
}

# 与上一次比较
if ($prev) {
    Write-Host ""
    Write-Host "与上次对比:"
    foreach ($k in @('slices', 'slices_pct', 'lut6', 'eram', 'dsps', 'setup_wns_ps')) {
        $a = $prev.$k; $b = $row[$k]
        if ($a -and $b -and $a -ne $b) {
            try {
                $d = [double]$b - [double]$a
                Write-Host ("  {0,-12} {1,10} -> {2,10}   ({3:+#;-#;0})" -f $k, $a, $b, $d)
            } catch { }
        }
    }
}

Write-Host ""
Write-Host "趋势表: $csv"
Write-Host "域裕量: $cw"

# ---------------------------------------------------------------- 门禁检查
#
# 三类结果：
#   硬失败  —— 负裕量 / setup 违例 / slices>80% / 显式 -Targets 未达
#   警告    —— 关键域裕量 < WarnSlack（默认 0.5ns），但没设该域目标
#   通过    —— 以上都没有
# 注意：lab3 基线本身就"不通过"（HDMI_PIXEL_CLK 0.103ns），这是 P0 要解决的问题。

$fail = @()
$warn = @()

if ($row.viol_sep -and [int]$row.viol_sep -ne 0) {
    $fail += "有 $($row.viol_sep) 个 setup 违例端点"
}
if ($row.slices_pct -and [double]$row.slices_pct -gt 80) {
    $fail += "slices 超过 80% ($($row.slices_pct)%)"
}

foreach ($c in $clockRows) {
    if (-not $c.name) { continue }

    if ($c.swns -lt 0) {
        $fail += "负裕量: $($c.name) = $($c.swns) ns"
        continue
    }

    # 显式目标（模糊匹配键名）
    $target = $null
    foreach ($k in $Targets.Keys) {
        if ($c.name -like "*$k*") { $target = [double]$Targets[$k]; break }
    }
    if ($null -ne $target) {
        if ($c.swns -lt $target) {
            $fail += "[目标] $($c.name) 裕量 $($c.swns) ns < $target ns"
        }
    } elseif ((Test-CriticalClock $c.name) -and $c.swns -lt $WarnSlack) {
        $warn += "$($c.name) 裕量 $($c.swns) ns < $WarnSlack ns（该域未设 -Targets）"
    }
}

if ($warn.Count -gt 0) {
    Write-Host ""
    Write-Host "注意 (不阻断):" -ForegroundColor Yellow
    $warn | ForEach-Object { Write-Host "   - $_" -ForegroundColor Yellow }
}

if ($fail.Count -gt 0) {
    Write-Host ""
    Write-Host "!! 门禁未通过:" -ForegroundColor Red
    $fail | ForEach-Object { Write-Host "   - $_" -ForegroundColor Red }
    exit 1
} else {
    Write-Host ""
    Write-Host "门禁通过 (无负裕量 / 无违例 / slices<=80% / 已达显式目标)" -ForegroundColor Green
    exit 0
}
