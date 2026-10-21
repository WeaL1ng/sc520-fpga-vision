# ============================================================
#  vopt_check.ps1 — 不需要许可证的"结构检查"（替代部分仿真价值）
#
#  背景：
#     ModelSim 的 vsim 需要许可证（本机没有），但 **vopt（详细化器）不需要**。
#     vopt 会真正做 elaboration：加载模块、解析端口连接、检查位宽、
#     展开层次、inlining。它能抓到的真实问题包括：
#       - 端口未连接 / 连接数不对            (vopt-2685 / vopt-2718)
#       - 位宽不匹配
#       - 模块未定义（拼写错误、漏编文件）
#       - 组合环路
#       - 层次引用找不到
#     它**不能**做的是：跑激励、看波形、验证功能正确性。那必须靠 vsim。
#
#  ⚠ 关键坑（已实测，写进脚本，避免再踩）：
#     1) 安路原语的库必须用 **+define+FORMAL_VERIFICATION** 编译，
#        否则 al_map_basic.v 会引用 glbl.gsrn（跨模块层次引用），vopt 报 vopt-7052。
#     2) 顶层必须例化两个全局单元，且**实例名必须正好是**：
#           glbl         glbl();
#           PH1P_PHY_GSR PH1P_PHY_GSR();
#        因为原语用的是层次名 /glbl/... 与 /PH1P_PHY_GSR/...。
#     3) vopt 的选项顺序：`-modelsimini` 必须在 designUnit **之前**。

#  用法：
#     powershell -ExecutionPolicy Bypass -File .\sim\vopt_check.ps1
#     powershell -ExecutionPolicy Bypass -File .\sim\vopt_check.ps1 -Clean
# ============================================================
[CmdletBinding()]
param(
    [string]$ModelRoot = 'F:\model',
    [string]$TdRoot    = 'F:\al',
    [string]$WorkDir   = '',
    [switch]$Clean,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$bin    = Join-Path $ModelRoot 'win64'
$simRel = Join-Path $TdRoot    'sim_release'
$vlog   = Join-Path $bin 'vlog.exe'
$vlib   = Join-Path $bin 'vlib.exe'
$vmap   = Join-Path $bin 'vmap.exe'
$vopt   = Join-Path $bin 'vopt.exe'

if (-not $WorkDir) { $WorkDir = Join-Path $PSScriptRoot 'vopt' }
if ($Clean -and (Test-Path $WorkDir)) {
    Write-Host "== -Clean：清空 $WorkDir" -ForegroundColor Yellow
    Get-ChildItem $WorkDir -Force | Where-Object { $_.Name -ne 'awb_vopt_top.v' } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$R = Join-Path $PSScriptRoot '..\rtl_vendor\anlogic_example\lab_ex3_osd_SC500_720P\lab_ex3_osd\user_source'

function Run([string]$exe, [string[]]$argv, [string]$what) {
    $o = & $exe @argv 2>&1
    $rc = $LASTEXITCODE
    if (-not $Quiet) {
        $errs = $o | Where-Object { $_ -match '\*\* Error' }
        if ($errs) { foreach ($e in $errs) { Write-Host "   $e" -ForegroundColor Red } }
    }
    return @{ rc = $rc; out = $o }
}

Push-Location $WorkDir
try {
    # ---------------------------------------------------------- 1. 建库 + 映射
    Write-Host "== [1/4] 建库与映射" -ForegroundColor Cyan
    foreach ($l in @('gf_common','gf_ph1p','work')) {
        if (-not (Test-Path $l)) { & $vlib $l | Out-Null }
    }
    & $vmap work       ./work       *> $null
    & $vmap gf_common  ./gf_common  *> $null
    & $vmap gf_ph1p    ./gf_ph1p    *> $null

    # ---------------------------------------------------------- 2. 编安路库
    #  只在库为空时编，避免每次重复（约 25 秒）
    $needCommon = -not (Test-Path (Join-Path (Join-Path $WorkDir 'gf_common') 'glbl'))
    if ($needCommon) {
        Write-Host "== [2/4] 编译安路原语库（+FORMAL_VERIFICATION，约 25s）" -ForegroundColor Cyan
        $common = @()
        $common += Get-ChildItem (Join-Path $simRel 'common\*.v')     -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
        $common += Get-ChildItem (Join-Path $simRel 'common\apm\*.v') -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
        $r1 = Run $vlog (@('-quiet','+define+FORMAL_VERIFICATION','-work','gf_common') + $common) 'common'
        if ($r1.rc -ne 0) { throw "gf_common 编译失败" }

        $ph1p = Get-ChildItem (Join-Path $simRel 'ph1p\*.v') -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
        $r2 = Run $vlog (@('-quiet','+define+FORMAL_VERIFICATION','-work','gf_ph1p') + $ph1p) 'ph1p'
        if ($r2.rc -ne 0) { throw "gf_ph1p 编译失败" }
        Write-Host "   OK" -ForegroundColor Green
    } else {
        Write-Host "== [2/4] 安路库已存在，跳过" -ForegroundColor DarkGray
    }

    # ---------------------------------------------------------- 3. 编被测设计
    Write-Host "== [3/4] 编译 awb 及其依赖" -ForegroundColor Cyan
    $design = @(
        (Join-Path $R 'ip_source\divider\divider_gate.v'),
        (Join-Path $R 'ip_source\blk_mem_gen_awb_delay_signal\blk_mem_gen_awb_delay_signal.v'),
        (Join-Path $R 'ip_source\blk_mem_gen_awb_delay_signal\ram_f84573da5ab5.v'),
        (Join-Path $R 'hdl_source\signal_delay.v'),
        (Join-Path $R 'hdl_source\awb.v'),
        (Join-Path $WorkDir 'awb_vopt_top.v')
    )
    $missing = $design | Where-Object { -not (Test-Path $_) }
    if ($missing) { throw "源文件缺失: $($missing -join ', ')" }
    $r3 = Run $vlog (@('-quiet','+define+FORMAL_VERIFICATION','-work','work') + $design) 'design'
    if ($r3.rc -ne 0) { throw "设计编译失败" }
    Write-Host "   OK" -ForegroundColor Green

    # ---------------------------------------------------------- 4. vopt 详细化
    Write-Host "== [4/4] vopt 详细化（结构检查）" -ForegroundColor Cyan
    $r4 = Run $vopt @('-L','gf_common','-L','gf_ph1p','work.awb_vopt_top','-o','awb_opt') 'vopt'

    $out = $r4.out
    $errs = @($out | Where-Object { $_ -match '\*\* Error' })
    $warns = @($out | Where-Object { $_ -match '\*\* Warning' })
    $loaded = @($out | Where-Object { $_ -match '^-- Loading module' })
    $inlined = @($out | Where-Object { $_ -match '^-- Inlining module' })

    Write-Host ""
    Write-Host "==================== vopt 结果 ====================" -ForegroundColor Green
    Write-Host ("  退出码      : {0}" -f $r4.rc)
    Write-Host ("  加载模块    : {0}" -f $loaded.Count)
    Write-Host ("  inlining    : {0}" -f $inlined.Count)
    Write-Host ("  Error       : {0}" -f $errs.Count)
    Write-Host ("  Warning     : {0}" -f $warns.Count)

    if ($warns.Count -gt 0) {
        Write-Host ""
        Write-Host "  --- Warning 明细（去重）---" -ForegroundColor Yellow
        $warns | ForEach-Object { ($_ -replace '^\*\* Warning:\s*','') } |
            Sort-Object -Unique | Select-Object -First 20 |
            ForEach-Object { Write-Host "    $_" }
    }

    Write-Host ""
    if ($r4.rc -eq 0) {
        Write-Host "  ✅ 结构检查通过（可以详细化 = 端口/位宽/层次都没问题）" -ForegroundColor Green
        Write-Host "     ⚠ 这不等于功能正确 —— 功能仍需 vsim 或上板验证。" -ForegroundColor Yellow
    } else {
        Write-Host "  ❌ 结构检查失败，见上面的 Error" -ForegroundColor Red
    }
    Write-Host "==================================================" -ForegroundColor Green
    exit $(if ($r4.rc -eq 0) { 0 } else { 1 })
}
finally { Pop-Location }
