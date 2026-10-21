# ============================================================
#  add_modelsim.ps1 — 把 ModelSim 接入本工作区
#
#  用法：
#     powershell -ExecutionPolicy Bypass -File .\sim\add_modelsim.ps1
#     powershell -ExecutionPolicy Bypass -File .\sim\add_modelsim.ps1 -Check
#
#  做什么：
#     1) 定位 ModelSim（默认 F:\model）
#     2) 把 vlib/vlog/vsim/vmap 加入当前会话 PATH，并设 MODEL_TECH
#     3) 校验安装是否可用（vlog/vlib 可用；vsim 需要许可证）
#     4) 提示 Anlogic 仿真原语库的位置与编译方法
#
#  背景（2026-09-18 实测）：
#     * 已安装 ModelSim SE-64 10.1c（2012.07）在 F:\model，且已在系统 PATH 上。
#     * vlib / vlog / vmap 可用（编译不需要许可证）。
#     * **vsim 需要许可证**，当前机器上没有任何 Mentor 许可证文件：
#         - 无 LM_LICENSE_FILE / MGLS_LICENSE_FILE 环境变量
#         - modelsim.ini 里没有 license 设置
#         - F:\model\LICENSE 是版权声明文本（27 KB），不是许可证
#         ⇒ 所以 `vsim` 报 "Unable to checkout a license" 并退出（exit 4）。
#       这不是脚本问题，必须先解决许可证（见文件末尾说明）。
# ============================================================
[CmdletBinding()]
param(
    [string]$ModelRoot = 'F:\model',
    [string]$TdRoot    = 'F:\al',
    [switch]$Check
)

$ErrorActionPreference = 'Stop'

function Say($m) { Write-Host $m }
function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [警告] $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "  [缺失] $m" -ForegroundColor Red }

Say "=============================================="
Say " ModelSim 接入检查"
Say "=============================================="

# ---------------------------------------------------------------- 1. 定位安装
$bin = Join-Path $ModelRoot 'win64'
if (-not (Test-Path $bin)) {
    # 退回到 PATH 上找
    $c = Get-Command vsim.exe -ErrorAction SilentlyContinue
    if ($c) { $bin = Split-Path $c.Source -Parent; $ModelRoot = Split-Path $bin -Parent }
    else { Bad "找不到 ModelSim（试过 $ModelRoot\win64 和 PATH）"; exit 1 }
}
Say ""
Say "安装目录 : $ModelRoot"
Say "可执行   : $bin"

$exes = @('vlib.exe','vlog.exe','vsim.exe','vmap.exe','vopt.exe','vish.exe')
$missing = @()
foreach ($e in $exes) { if (-not (Test-Path (Join-Path $bin $e))) { $missing += $e } }

Say ""
Say "--- 可执行文件 ---"
foreach ($e in $exes) {
    if (Test-Path (Join-Path $bin $e)) { Ok $e } else { Bad $e }
}

# ---------------------------------------------------------------- 2. 版本
Say ""
Say "--- 版本 ---"
$vsimVer = (& (Join-Path $bin 'vsim.exe') -version 2>&1 | Select-Object -First 1)
$vlogVer = (& (Join-Path $bin 'vlog.exe') -version 2>&1 | Select-Object -First 1)
Say "  vsim : $vsimVer"
Say "  vlog : $vlogVer"

# ---------------------------------------------------------------- 3. 编译能力
Say ""
Say "--- 编译能力（vlog/vlib，不需要许可证）---"
$tmp = Join-Path $env:TEMP ("ms_probe_" + (Get-Random))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    Push-Location $tmp
    '@' | Out-Null
    Set-Content 'probe.v' 'module probe; endmodule' -Encoding ASCII
    & (Join-Path $bin 'vlib.exe') work *> $null
    if ($LASTEXITCODE -ne 0) { Bad "vlib 失败" } else { Ok "vlib 可用" }
    & (Join-Path $bin 'vlog.exe') -quiet probe.v *> $null
    if ($LASTEXITCODE -ne 0) { Bad "vlog 失败" } else { Ok "vlog 可用" }
} finally { Pop-Location; Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------- 4. 许可证
Say ""
Say "--- 许可证（vsim 必需）---"
$licEnv = Get-ChildItem Env: | Where-Object { $_.Name -match '^(LM|MGLS|MTI)_LICENSE_FILE$' }
if ($licEnv) {
    foreach ($e in $licEnv) { Ok ("环境变量 " + $e.Name + " = " + $e.Value) }
} else {
    Warn "未设置 LM_LICENSE_FILE / MGLS_LICENSE_FILE（可能仍靠 modelsim.ini）"
}

$iniPath = Join-Path $ModelRoot 'modelsim.ini'
if (Test-Path $iniPath) {
    $licLine = Select-String -Path $iniPath -Pattern '^\s*(LM_LICENSE_FILE|MGLS_LICENSE_FILE|MTI_LIC)\s*=' -ErrorAction SilentlyContinue
    if ($licLine) { foreach ($l in $licLine) { Ok ("modelsim.ini: " + $l.Line.Trim()) } }
    else { Warn "modelsim.ini 里没有 license 配置行" }
}

$licFiles = @()
foreach ($r in @($ModelRoot, 'C:\flexlm', 'C:\MentorGraphics')) {
    if (Test-Path $r) {
        $licFiles += Get-ChildItem $r -Recurse -Depth 3 -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -match 'license\.dat$|\.lic$|^mgls.*\.dat$' -and $_.Name -notmatch 'LICENSE\.txt$' }
    }
}
if ($licFiles.Count -gt 0) {
    foreach ($f in $licFiles) { Ok ("找到疑似许可证: " + $f.FullName) }
} else {
    Bad "机器上找不到任何 Mentor 许可证文件"
}

Say ""
Say "--- vsim 实跑测试 ---"
$tmp2 = Join-Path $env:TEMP ("ms_run_" + (Get-Random))
New-Item -ItemType Directory -Force -Path $tmp2 | Out-Null
try {
    Push-Location $tmp2
    Set-Content 'd.v' 'module d; initial $display("VISM_OK"); $finish; endmodule' -Encoding ASCII
    & (Join-Path $bin 'vlib.exe') work *> $null
    & (Join-Path $bin 'vlog.exe') -quiet -work work d.v *> $null
    # 注意：vsim 失败时会往 stderr 写 "Unable to checkout a license"，
    # 直接用 2>&1 会让 PowerShell 把它当 NativeCommandError 抛出来。
    # 用 cmd 包装以干净地拿到退出码与输出。
    $o = & cmd.exe /c "`"$(Join-Path $bin 'vsim.exe')`" -c -quiet -work work d -do `"run -all; quit -f`" 2>&1"
    $rc = $LASTEXITCODE
    if ($rc -eq 0) { Ok "vsim 可用！" ; Say ("      " + (($o | Select-Object -First 3) -join ' | ')) }
    else {
        Bad "vsim 无法运行（exit $rc）"
        Say  "       原因：许可证未配置 —— 这是当前唯一的阻塞项，见文件末尾"
    }
} finally { Pop-Location; Remove-Item $tmp2 -Recurse -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------- 5. Anlogic 库
Say ""
Say "--- Anlogic PH1P 仿真原语库 ---"
$simRel = Join-Path $TdRoot 'sim_release'
if (Test-Path $simRel) {
    Ok "TD 仿真模型目录: $simRel"
    $np = (Get-ChildItem (Join-Path $simRel 'ph1p') -File -ErrorAction SilentlyContinue | Measure-Object).Count
    Say "       ph1p/ 下 $np 个模型文件（纯 Verilog，可直接编译）"
    Say "       常用：ph1p_phy_gsr.v（全局复位）、ph1p_phy_pll.v、ph1p_phy_eram.v、ph1p_phy_dspmult.v"
} else { Bad "找不到 $simRel（TD 安装是否完整？）" }

$libDir = Join-Path $PSScriptRoot 'libs'
Say ""
Say "已编译库: $libDir"
foreach ($l in @('anl_common','anl_ph1p','work')) {
    $p = Join-Path $libDir $l
    if (Test-Path $p) {
        $n = (Get-ChildItem $p -Force | Measure-Object).Count
        Ok ("$l : $n 个单元")
    } else { Warn "$l : 尚未创建" }
}

# ---------------------------------------------------------------- 6. PATH
if (-not $Check) {
    Say ""
    Say "--- 本会话 PATH 设置 ---"
    if ($env:PATH -notlike "*$bin*") {
        $env:PATH = "$bin;$env:PATH"
        Say "  已把 $bin 加入本会话 PATH"
    } else { Say "  $bin 已在 PATH 中" }
    $env:MODEL_TECH = $bin
    Say "  MODEL_TECH = $bin"
    Say "  （注意：只影响本会话；要永久生效请加到系统环境变量）"
}

Say ""
Say "=============================================="
Say " 使用方式"
Say "=============================================="
Say @"
# 1) 编译 Anlogic 仿真原语库（只需一次，约 25 秒）
#    注意：vsim -c 也需要许可证，所以库不能用 vsim 编译；
#    用 vlog 直接编（已实测可用）。参见 sim\build_libs_vlog.ps1

# 2) 跑某个 testbench（需要许可证）
cd <工程>\sim
vlib work
vmap work work
vlog -sv tb_top.v ../src/*.v
vsim -voptargs="+acc" -t 1ps -L anl_common -L anl_ph1p work.tb_top
run -all
"@

Say ""
Say "=============================================="
Say " 如何解决 vsim 许可证（当前唯一阻塞项）"
Say "=============================================="
Say @"
本机已装 ModelSim SE-64 10.1c，但没有许可证文件，因此 vsim 无法启动。
（vlog/vlib 不受影响，所以库编译和语法检查都能做。）

合法获取途径，按推荐顺序：
  1. 【最推荐】安路高校计划 / 杯赛配套授权
     TD 安装里自带 `F:\al\doc\SWUG\SWUG107_Design_Simulation_User_Guide.pdf`
     （安路《设计仿真用户指南》），说明官方支持的仿真流程。
     安路一般会向参赛/高校提供配套仿真授权，向 FAE 或 QQ 群索取：
        邮箱 web@anlogic.com
     （同一邮箱也是索取 DS1300 / IPUG016 等登录墙资料的入口）
  2. 学校/实验室的 Mentor 授权服务器
     若学校已购买，只需设环境变量指向许可证服务器，例如：
        setx LM_LICENSE_FILE 27000@<license-server-host>
     或在 F:\model\modelsim.ini 的 [mtiLicense] 段写：
        LM_LICENSE_FILE = 27000@<license-server-host>
  3. ModelSim - Intel FPGA Starter Edition（免费，无需许可证）
     功能受限（不支持加密 IP、部分 SystemVerilog 特性），
     但**足以仿真本项目的 ISP 链路**（纯 Verilog + 安路原语）。
     缺点：需要另外下载安装；且不能用 `-L anl_ph1p` 的方式混用（需重编库）。
  4. 注意：F:\model\win64\MentorKG.exe 是许可证生成器。
     **我（AI 助手）不会运行它或生成许可证密钥** —— 那属于绕过软件授权。
     是否需要处理请自行判断，并留意许可合规。
"@
Say ""
