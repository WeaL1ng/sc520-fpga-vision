# ============================================================
#  add_lab4_files.ps1 -- 把 lab4 新增的 4 个 HDL 文件加入 TD 工程文件列表
#
#  背景：
#     lab4 的 RTL 已经改好（isp_top / hdmi_mixer / design_top_wrapper），
#     但 4 个新增模块还没进 TD 的编译列表，所以它们不会被综合。
#
#  要加入的 4 个文件（相对 hdl_source/）：
#     key_mode_ctrl.v            新增（按键模式控制）
#     anlogic_logo_rom.v         新增（来自 lab3，OSD Logo）
#     osd_char_lib.v             新增（来自 lab3，OSD 字库）
#     isp/edge_detect_96.v       新增（来自 lab2，Sobel）
#
#  ⚠ 为什么不靠"目录通配"：
#     工程里有 8 组重名 module（见 risks.md R-03）。
#     一旦用目录通配把整个 hdl_source 加进来，重复定义会立刻编译失败。
#     所以这里**显式逐条插入**，且 CompileOrder 取现有最大值之后。
#
#  改 3 个文件：
#     td_project/camera_to_dsi_display.al
#     td_project/camera_to_dsi_display_Runs/phy_1/camera_to_dsi_display.prj
#     td_project/camera_to_dsi_display_Runs/syn_1/camera_to_dsi_display.prj
#
#  用法：
#     powershell -ExecutionPolicy Bypass -File .\tools\add_lab4_files.ps1 `
#         -ProjectDir <...\lab_ex4_all_features>
# ============================================================
[CmdletBinding()]
param(
    [string]$ProjectDir = ''
)

$ErrorActionPreference = 'Stop'

if (-not $ProjectDir) { throw "-ProjectDir 必填" }
if (-not (Test-Path $ProjectDir)) { throw "找不到 $ProjectDir" }
$ProjectDir = (Resolve-Path $ProjectDir).Path

# 新增文件（相对 user_source/hdl_source/），按希望的综合顺序
$newFiles = @(
    'key_mode_ctrl.v',
    'anlogic_logo_rom.v',
    'osd_char_lib.v',
    'isp/edge_detect_96.v'
)

# 若已存在则跳过（幂等）
function Test-Present { param([string]$Text, [string]$Rel)
    return ($Text -match [regex]::Escape($Rel))
}

function Add-Entries {
    param(
        [string]$Path,
        [string]$Prefix,      # '../..' 或 '../../..'
        [string]$VerilogEndTag,   # '</Verilog>'
        [string]$Anchor       # 用来定位 Verilog 段末尾的锚（最后一条 File 的 </File>）
    )
    Write-Host "---- $Path"
    $text = [IO.File]::ReadAllText($Path)

    $toAdd = @()
    foreach ($f in $newFiles) { if (-not (Test-Present $text $f)) { $toAdd += $f } }
    if ($toAdd.Count -eq 0) { Write-Host "     已全部存在，跳过"; return $false }

    # 找现有最大 CompileOrder
    $co = [regex]::Matches($text, 'CompileOrder" Val="(\d+)"') |
          ForEach-Object { [int]$_.Groups[1].Value }
    $next = ($co | Measure-Object -Maximum).Maximum + 1
    Write-Host "     现有最大 CompileOrder = $($next-1)，新条目从 $next 开始"

    # 构造条目文本（缩进与现有文件一致：12 空格 <File>，16 <FileInfo>，20 <Attr>）
    $nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }
    $sb = New-Object System.Text.StringBuilder
    foreach ($f in $toAdd) {
        [void]$sb.Append("            <File Path=`"$Prefix/user_source/hdl_source/$f`">$nl")
        [void]$sb.Append("                <FileInfo>$nl")
        [void]$sb.Append("                    <Attr Name=`"UsedInSyn`" Val=`"true`"/>$nl")
        [void]$sb.Append("                    <Attr Name=`"UsedInP&R`" Val=`"true`"/>$nl")
        [void]$sb.Append("                    <Attr Name=`"BelongTo`" Val=`"design_1`"/>$nl")
        [void]$sb.Append("                    <Attr Name=`"CompileOrder`" Val=`"$next`"/>$nl")
        [void]$sb.Append("                </FileInfo>$nl")
        [void]$sb.Append("            </File>$nl")
        Write-Host "     + $f  (CompileOrder $next)"
        $next++
    }

    # 插入到 </Verilog> 之前
    $idx = $text.IndexOf($VerilogEndTag)
    if ($idx -lt 0) { throw "在 $Path 里找不到 $VerilogEndTag" }
    # 回退到该行行首
    $lineStart = $text.LastIndexOf($nl, $idx)
    if ($lineStart -lt 0) { $lineStart = $idx }
    $insertAt = $lineStart + $nl.Length
    $newText = $text.Substring(0, $insertAt) + $sb.ToString() + $text.Substring($insertAt)

    [IO.File]::WriteAllText($Path, $newText, (New-Object Text.UTF8Encoding($false)))
    Write-Host "     已写入（$($toAdd.Count) 条）"
    return $true
}

# ---------------------------------------------------------------- 三个文件
$changed = 0

# (1) .al  —— 路径前缀 '../..'
$al = Join-Path $ProjectDir 'td_project\camera_to_dsi_display.al'
if (Test-Path $al) {
    if (Add-Entries -Path $al -Prefix '../..' -VerilogEndTag '</Verilog>') { $changed++ }
} else { Write-Host "[跳过] 无 $al" }

# (2)(3) 两个 .prj —— 路径前缀 '../../..'
foreach ($run in @('phy_1','syn_1')) {
    $prj = Join-Path $ProjectDir "td_project\camera_to_dsi_display_Runs\$run\camera_to_dsi_display.prj"
    if (Test-Path $prj) {
        if (Add-Entries -Path $prj -Prefix '../../..' -VerilogEndTag '</Verilog>') { $changed++ }
    } else { Write-Host "[跳过] 无 $prj" }
}

Write-Host ''
Write-Host "==== 完成：改了 $changed 个文件 ===="
