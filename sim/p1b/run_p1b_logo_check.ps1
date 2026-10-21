# ============================================================
#  run_p1b_logo_check.ps1 -- P1b Logo 位置验证（一键，多软件）
#
#  验证链（三个互相独立的实现）
#    ① ModelSim  : 编译 hdmi_mixer + logo_rom_eram + osd_char_lib + TB，
#                  跑两次仿真（+osd=0 / +osd=1），导出 1280x720 逐像素文本
#    ② ModelSim  : 两次输出的 DE 像素数必须精确等于 1280x720
#    ③ Python    : 直接从 logo_pixel.mif + logo_palette.vh 算"期望包围盒"，
#                  再把两次仿真的差集当"实测包围盒"，两者比对
#
#  为什么这样做
#    P1b 把 Logo ROM 改成同步读（多 1 拍），把地址计算提前到 _1d 坐标级来
#    吸收这一拍。这个对齐原来是推导，本脚本把它变成**可复现的实测**。
#    用"两次仿真做差"而不是在 TB 里解码背景，是为了避开对背景编码的假设。
#
#  用法：
#     powershell -ExecutionPolicy Bypass -File .\sim\p1b\run_p1b_logo_check.ps1
# ============================================================
[CmdletBinding()]
param(
    # ⚠ 2026-09-21 更正：默认工程改为**当前正式工程**。
    #   原来默认指向 `_stage/lab_ex4_p1b_SC500_720P/...`（P1b 时期的冻结副本），
    #   该副本的 `hdmi_mixer.v` 是旧版（没有 P3 新增的 I_lat_* / O_dis_frame_start 端口），
    #   会导致 vsim 报端口不匹配并**不产生任何输出文件**。
    #   本脚本的用途是"验证当前版本的 Logo 位置"，因此必须指向当前工程。
    [string]$ProjectDir = '',
    [string]$ModelSimBin = 'F:\modelsim\modelsim_ase\win32aloem',
    [string]$TbFile = '',
    [string]$CheckPy = '',
    [string]$WorkDir = ''
)

$w = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
if (-not $ProjectDir) { $ProjectDir = Join-Path $w 'rtl_vendor\anlogic_example\lab_ex4_all_features_SC500_720P\lab_ex4_all_features' }
if (-not $TbFile) { $TbFile = Join-Path $w 'sim\p1b\tb_hdmi_mixer_logo.v' }
if (-not $CheckPy) { $CheckPy = Join-Path $w 'tools\check_logo_position.py' }
if (-not $WorkDir) { $WorkDir = Join-Path $w '_stage\p1b_logo_check' }

$ErrorActionPreference = 'Stop'
$vlib = Join-Path $ModelSimBin 'vlib.exe'
$vlog = Join-Path $ModelSimBin 'vlog.exe'
$vsim = Join-Path $ModelSimBin 'vsim.exe'
foreach ($t in @($vlib, $vlog, $vsim)) { if (-not (Test-Path $t)) { throw "not found: $t" } }

$hdl = Join-Path $ProjectDir 'user_source\hdl_source'
foreach ($f in @('hdmi_mixer.v', 'logo_rom_eram.v', 'osd_char_lib.v')) {
    if (-not (Test-Path (Join-Path $hdl $f))) { throw "not found: $hdl\$f" }
}

if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
Push-Location $WorkDir

Write-Host ''
Write-Host '===== [1/3] ModelSim: compile ====='
& $vlib work | Out-Null
$c = & $vlog -work work `
        (Join-Path $hdl 'hdmi_mixer.v') `
        (Join-Path $hdl 'logo_rom_eram.v') `
        (Join-Path $hdl 'osd_char_lib.v') `
        $TbFile 2>&1
$c | Where-Object { $_ -match 'Error|Errors:|Compiling' } | ForEach-Object { Write-Host "  $_" }
if (($c | Select-String 'Errors: 0' -Quiet) -ne $true) { Pop-Location; throw 'compile failed' }

Write-Host ''
Write-Host '===== [2/3] ModelSim: two runs (osd=0 / osd=1) ====='
foreach ($case in @(@{osd=0; out='logo_osd0.hex'}, @{osd=1; out='logo_osd1.hex'})) {
    $t0 = Get-Date
    $o = & $vsim -batch -lib work tb_hdmi_mixer_logo -do "run -all; quit -f" `
            "+osd=$($case.osd)" "+out=$($case.out)" 2>&1
    $o | Where-Object { $_ -match 'osd_sw|\[ ok \]|\[FAIL\]|DE pixel|TB done|Errors:' } |
        ForEach-Object { Write-Host ("  " + ($_ -replace '^\s*#\s?', '')) }
    Write-Host ("  elapsed {0:N1}s" -f ((Get-Date) - $t0).TotalSeconds)
    if (-not (Test-Path $case.out)) { Pop-Location; throw "no output: $($case.out)" }
}

Write-Host ''
Write-Host '===== [3/3] Python: independent position check ====='
$env:PYTHONIOENCODING = 'utf-8'
& python $CheckPy --sim-dir $WorkDir 2>&1 | ForEach-Object { Write-Host "  $_" }
$rc = $LASTEXITCODE

Pop-Location
Write-Host ''
if ($rc -eq 0) { Write-Host 'RESULT: PASS  (Logo position exact, no 1-pixel shift)' }
else           { Write-Host "RESULT: FAIL  (exit $rc)" }
exit $rc
