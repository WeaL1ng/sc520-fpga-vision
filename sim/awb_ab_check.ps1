# ============================================================
#  awb_ab_check.ps1 — 无许可证的 A/B 结构对比
#
#  问题：没有 vsim 许可证 ⇒ 无法做功能仿真 ⇒ 无法直接证明
#        "AWB 重构后输出逐位一致"。
#
#  本脚本提供**次优但真实**的证据：
#     把「改前」与「改后」两个版本的 awb.v 分别详细化（vopt），
#     对比 vopt 的结构检查结果指纹（归一化后的 Warning 集合）。
#     - 指纹相同 ⇒ 端口连接/位宽/层次结构未发生变化
#       （因为改后的警告集合里没有**新增**条目）
#     - 出现新增警告 ⇒ 改动引入了结构性差异，必须人工排查
#
#  ⚠ 诚实的边界：这**不能**证明功能等价。
#     bit 级等价仍需 vsim（或上板）。本脚本只排除"结构性回归"。
#
#  用法：
#     powershell -ExecutionPolicy Bypass -File .\sim\awb_ab_check.ps1 `
#         -Before <改动前的 awb.v>  -After <改动后的 awb.v>
#
#     不给参数时：Before = rtl_vendor 里的原版；After = -AfterPath（默认同原版，即自比自，用于验证脚本本身）
# ============================================================
[CmdletBinding()]
param(
    [string]$Before,
    [string]$After,
    [string]$ModelRoot = 'F:\model',
    [string]$TdRoot    = 'F:\al',
    [string]$OutDir    = ''
)

$ErrorActionPreference = 'Stop'
$bin  = Join-Path $ModelRoot 'win64'
$vlib = Join-Path $bin 'vlib.exe'
$vlog = Join-Path $bin 'vlog.exe'
$vmap = Join-Path $bin 'vmap.exe'
$vopt = Join-Path $bin 'vopt.exe'
$simRel = Join-Path $TdRoot 'sim_release'

$R = Join-Path $PSScriptRoot '..\rtl_vendor\anlogic_example\lab_ex3_osd_SC500_720P\lab_ex3_osd\user_source'
if (-not $Before) { $Before = Join-Path $R 'hdl_source\awb.v' }
if (-not $After)  { $After  = $Before }
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'ab' }

foreach ($p in @($Before, $After)) {
    if (-not (Test-Path $p)) { throw "awb.v 不存在: $p" }
}
Write-Host "== Before : $Before"
Write-Host "== After  : $After"
Write-Host "== OutDir : $OutDir"

$deps = @(
    (Join-Path $R 'ip_source\divider\divider_gate.v'),
    (Join-Path $R 'ip_source\blk_mem_gen_awb_delay_signal\blk_mem_gen_awb_delay_signal.v'),
    (Join-Path $R 'ip_source\blk_mem_gen_awb_delay_signal\ram_f84573da5ab5.v'),
    (Join-Path $R 'hdl_source\signal_delay.v')
)
$top = Join-Path $PSScriptRoot 'vopt\awb_vopt_top.v'

function Get-Fingerprint {
    param([string]$AwbPath, [string]$Tag)
    $work = Join-Path $OutDir $Tag
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    Push-Location $work
    try {
        foreach ($l in @('work','gf_common','gf_ph1p')) {
            if (-not (Test-Path $l)) { & $vlib $l | Out-Null }
        }
        & $vmap work      ./work      *> $null
        & $vmap gf_common ./gf_common *> $null
        & $vmap gf_ph1p   ./gf_ph1p   *> $null

        # 安路库为空则先编（用 FORMAL_VERIFICATION，见 vopt_check.ps1 的说明）
        if (-not (Test-Path (Join-Path $work 'gf_common\glbl'))) {
            $c = @()
            $c += Get-ChildItem (Join-Path $simRel 'common\*.v')     -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
            $c += Get-ChildItem (Join-Path $simRel 'common\apm\*.v') -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
            & $vlog -quiet +define+FORMAL_VERIFICATION -work gf_common @c *> $null
            $p = Get-ChildItem (Join-Path $simRel 'ph1p\*.v') -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
            & $vlog -quiet +define+FORMAL_VERIFICATION -work gf_ph1p @p *> $null
        }

        $files = @($deps + $AwbPath + $top)
        & $vlog -quiet +define+FORMAL_VERIFICATION -work work @files *> $null

        $o = & $vopt -L gf_common -L gf_ph1p work.awb_vopt_top -o "awb_opt_$Tag" 2>&1
        $rc = $LASTEXITCODE

        # 归一化：去掉绝对路径前缀、去掉实例名后缀里的随机哈希，只留"文件(行): 消息类型 描述"
        $fp = $o | Where-Object { $_ -match '\*\* (Warning|Error)' } | ForEach-Object {
            $s = $_
            $s = $s -replace '^\*\* (Warning|Error):\s*',''
            $s = $s -replace [regex]::Escape($work),'<WORK>'
            $s = $s -replace [regex]::Escape((Split-Path $AwbPath -Parent)),'<RTL>'
            $s = $s -replace 'al_[0-9a-f]{6,}','al_<HASH>'
            $s = $s -replace '\\','/'
            $s.Trim()
        } | Sort-Object -Unique

        return @{ rc = $rc; fp = $fp; raw = $o }
    } finally { Pop-Location }
}

Write-Host ""
Write-Host "== 详细化 Before ..." -ForegroundColor Cyan
$b = Get-Fingerprint -AwbPath $Before -Tag 'before'
Write-Host ("   exit={0}  警告种类={1}" -f $b.rc, $b.fp.Count)

Write-Host "== 详细化 After ..." -ForegroundColor Cyan
$a = Get-Fingerprint -AwbPath $After -Tag 'after'
Write-Host ("   exit={0}  警告种类={1}" -f $a.rc, $a.fp.Count)

$new = @(Compare-Object $b.fp $a.fp | Where-Object { $_.SideIndicator -eq '=>' } | ForEach-Object { $_.InputObject })
$gone = @(Compare-Object $b.fp $a.fp | Where-Object { $_.SideIndicator -eq '<=' } | ForEach-Object { $_.InputObject })

Write-Host ""
Write-Host "==================== A/B 结构对比 ====================" -ForegroundColor Green
Write-Host ("  Before 退出码 : {0}" -f $b.rc)
Write-Host ("  After  退出码 : {0}" -f $a.rc)
Write-Host ("  新增警告      : {0}" -f $new.Count)
Write-Host ("  消失警告      : {0}" -f $gone.Count)

if ($new.Count -gt 0) {
    Write-Host ""
    Write-Host "  --- 新增（必须排查）---" -ForegroundColor Red
    $new | Select-Object -First 15 | ForEach-Object { Write-Host "    + $_" }
}
if ($gone.Count -gt 0) {
    Write-Host ""
    Write-Host "  --- 消失（通常是好事）---" -ForegroundColor Yellow
    $gone | Select-Object -First 15 | ForEach-Object { Write-Host "    - $_" }
}

Write-Host ""
if ($new.Count -eq 0 -and $a.rc -eq 0) {
    Write-Host "  ✅ 无结构性回归：改动没有引入新的端口/位宽/层次问题" -ForegroundColor Green
} else {
    Write-Host "  ⚠ 存在差异，请人工确认上面列出的条目" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  ⚠ 再次强调：本检查**不能**证明功能（bit 级）等价。" -ForegroundColor Yellow
Write-Host "     功能等价仍需 vsim 仿真或上板验证。" -ForegroundColor Yellow
Write-Host "=====================================================" -ForegroundColor Green
