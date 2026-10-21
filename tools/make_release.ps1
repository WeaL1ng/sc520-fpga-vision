# ============================================================
#  make_release.ps1 -- one-click release package for the current build
#
#  Copies (a) the bitstreams + TD reports and (b) the *modified RTL sources*
#  that produced them, into _stage/<tag>_release_<timestamp>/  and prints a
#  SHA256 for the bitstream so a bitstream can always be traced back to sources.
#
#  ASCII only on purpose: a .ps1 containing Chinese needs a UTF-8 BOM or
#  PowerShell 5.1 reads it as GBK and fails to parse.
#
#  Usage:
#     powershell -ExecutionPolicy Bypass -File .\tools\make_release.ps1 -Tag lab4_p6
# ============================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Tag,
    [string]$ProjectRoot = '',
    [string]$StageRoot = '',
    [switch]$Plain
)

$w = (Split-Path -Parent $PSScriptRoot)
if (-not $ProjectRoot) { $ProjectRoot = Join-Path $w 'rtl_vendor\anlogic_example\lab_ex4_all_features_SC500_720P\lab_ex4_all_features' }
if (-not $StageRoot) { $StageRoot = Join-Path $w '_stage' }

$ErrorActionPreference = 'Stop'
$hdl = Join-Path $ProjectRoot 'user_source\hdl_source'
$phy = Join-Path $ProjectRoot 'td_project\camera_to_dsi_display_Runs\phy_1'
$tp  = Join-Path $ProjectRoot 'td_project'

$stamp = Get-Date -Format 'yyyyMMdd_HHmm'
$dst = Join-Path $StageRoot ("{0}_release_{1}" -f $Tag, $stamp)
New-Item -ItemType Directory -Force -Path $dst | Out-Null

# ---- 1. bitstreams + reports ----
$art = @(
    @{ s = (Join-Path $phy 'camera_to_dsi_display.bit');          d = 'camera_to_dsi_display.bit' },
    @{ s = (Join-Path $phy 'camera_to_dsi_display_compress.bit'); d = 'camera_to_dsi_display_compress.bit' },
    @{ s = (Join-Path $phy 'camera_to_dsi_display_phy.area');     d = 'camera_to_dsi_display_phy.area' },
    @{ s = (Join-Path $phy 'camera_to_dsi_display_pr.timing');    d = 'camera_to_dsi_display_pr.timing' },
    @{ s = (Join-Path $phy 'camera_to_dsi_display_chk.timing');   d = 'camera_to_dsi_display_chk.timing' },
    @{ s = (Join-Path $tp  'camera_to_dsi_display.sdc');          d = 'camera_to_dsi_display.sdc' }
)
foreach ($a in $art) {
    if (Test-Path $a.s) { Copy-Item $a.s (Join-Path $dst $a.d) -Force }
    else { Write-Host ("  [WARN] missing: " + $a.s) }
}

# ---- 2. RTL sources (flat copy, same layout as previous releases) ----
$srcs = @(
    'design_top_wrapper.v', 'key_mode_ctrl.v', 'hdmi_mixer.v', 'osd_char_lib.v',
    'video_in.v', 'video_out.v', 'frame_latency.v', 'logo_rom_eram.v',
    'isp\isp_top.v', 'isp\gray_binary_96.v', 'isp\cartoon_96.v',
    'isp\target_detect_96.v', 'isp\luma_stats.v',
    'ae_ctrl.v', 'uiisp_beta\ae_set.v',
    'uics520_cfg\uicfgcs520.v', 'uics520_cfg\uics520reg_720p60.v',
    'uics520_cfg\uics520regAE.v', 'uics520_cfg\SC520GainTbl.v',
    'uics500_cfg\uii2c.v'
)
foreach ($f in $srcs) {
    $p = Join-Path $hdl $f
    if (Test-Path $p) { Copy-Item $p (Join-Path $dst (Split-Path $f -Leaf)) -Force }
    else { Write-Host ("  [WARN] missing source: " + $f) }
}

# ---- 3. hash + summary ----
$bit = Join-Path $dst 'camera_to_dsi_display.bit'
$h = if (Test-Path $bit) { (Get-FileHash $bit -Algorithm SHA256).Hash } else { 'N/A' }
$n = (Get-ChildItem $dst -File).Count
$sz = [math]::Round(((Get-ChildItem $dst -File | Measure-Object Length -Sum).Sum / 1MB), 2)

Write-Host ''
Write-Host ('=' * 66)
Write-Host (" release dir : " + $dst)
Write-Host (" files       : {0}   total {1} MB" -f $n, $sz)
Write-Host (" bitstream   : " + (Split-Path $bit -Leaf) + "  " + (Get-Item $bit).Length + " bytes")
Write-Host (" SHA256      : " + $h)
Write-Host ('=' * 66)
