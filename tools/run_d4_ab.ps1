# ============================================================================
#  run_d4_ab.ps1  ---  awb 吞吐三级对照 + 恢复验证
#
#  用 divider_beh.v（50 拍延迟 / 1 结果每拍的行为模型，已与门级网表逐拍核对）
#  替换 divider_gate.v（64k 行，会把仿真拖超时）。
#
#  激励为**真实突发形态**：每行 320 字连续突发 + 51 拍空档
#  （来自 awb 内 signal_delay 的 rd_valid 窗口，见 signal_delay.v:76-80）。
#  这一点至关重要：若按均匀流灌数据，会低估 FIFO 溢出，得出假"达标"结论。
#
#  三个 DUT：
#    ref     : awb_ref                 厂商原版副本（8 并行乘法器，无 FIFO）
#    fixed   : lab4 hdl_source/awb.v   ★ 当前工程实际参与构建的文件
#    unfixed : awb_d4unfixed           仅回退 D4 的 P1a TDM 版（历史对照）
#
#  判据：drop_cnt == 0 且 cyc/out <= 4.34
#        4.34 = MIPI_RX_BYTE_CLK 59.995MHz / 13.824M 字每秒
#        （59.995MHz 取自 phy 布线报告 clk0；13.824M = 55.296Mpix/s ÷ 4pix/字）
#
#  注意：`+define+` 的名字必须是合法 Verilog 标识符。宏名若以数字开头
#        （例如 d4unfixed），预处理器会静默忽略，ifdef 全部落空。
# ============================================================================
param(
    [string]$ProjectRoot = '',
    [ValidateSet("all","ref","fixed","unfixed")]
    [string]$Which = "all",
    [switch]$NoBuild
)

$w = (Split-Path -Parent $PSScriptRoot)
if (-not $ProjectRoot) { $ProjectRoot = Join-Path $w 'rtl_vendor\anlogic_example\lab_ex4_all_features_SC500_720P\lab_ex4_all_features' }

$ErrorActionPreference = "Stop"
$w    = (Split-Path -Parent $PSScriptRoot)
$sim  = "$w\rtl_vendor\anlogic_example\lab_ex4_all_features_SC500_720P\sim\p1a_awb"
$work = "$w\_stage\d4_rate2"

$vlog = "F:\modelsim\modelsim_ase\win32aloem\vlog.exe"
$vsim = "F:\modelsim\modelsim_ase\win32aloem\vsim.exe"
$vlib = "F:\modelsim\modelsim_ase\win32aloem\vlib.exe"

foreach ($e in @($vlog,$vsim,$vlib)) {
    if (-not (Test-Path $e)) { throw "找不到 $e" }
}

$common = @(
    "F:/al/sim_release/common/al_map_basic.v",
    "F:/al/sim_release/common/al_map_lut.v",
    "F:/al/sim_release/common/al_map_adder.v",
    "F:/al/sim_release/common/al_phy_glbl.v"
)
$models = @(
    "$sim/rtl/divider_beh.v",
    "$sim/rtl/awb_ram_sim.v",
    "$ProjectRoot/user_source/hdl_source/signal_delay.v",
    "$ProjectRoot/user_source/ip_source/w155_d512_fifo/w155_d512_fifo.v",
    "$ProjectRoot/user_source/ip_source/w155_d512_fifo/soft_fifo_al_f58e8b3e1f3d.v"
)
$tb = "$w/sim/p1b/tb_awb_rate3.v"

function Invoke-Case {
    param([string]$Tag, [string]$DutPath, [string[]]$Defines)

    $dir = "$work\$Tag"
    if (-not $NoBuild) {
        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Set-Location $dir

    Write-Host ""
    Write-Host "============================================================"
    Write-Host " [$Tag]  DUT = $(Split-Path $DutPath -Leaf)   defines=[$($Defines -join ' ')]"
    Write-Host "============================================================"

    & $vlib work | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "vlib 失败" }

    $srcs = $common + $models + @($DutPath, $tb)
    & $vlog -work work @Defines @srcs 2>&1 |
        Tee-Object -FilePath "$dir\compile.log" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "[$Tag] vlog 编译失败" }
    $cerr = (Select-String -Path "$dir\compile.log" -Pattern 'Errors:\s*(\d+)' |
             Select-Object -Last 1).Matches.Groups[1].Value
    Write-Host "  编译: Errors=$cerr"

    # ASE 无 vopt；必须加载 work.glbl 作为附加 top（供应商原语要用）
    $vargs = @("-batch", "-lib", "work", "tb_awb_rate3", "work.glbl",
               "-do", "run -all; quit -f")
    & $vsim @vargs 2>&1 | Tee-Object -FilePath "$dir\sim.log" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "[$Tag] vsim 失败" }

    Select-String -Path "$dir\sim.log" `
        -Pattern "DUT =|cycles per OUTPUT|drop_cnt|FIFO peak|first drop|window out|\[PASS\]|\[FAIL\]" |
        ForEach-Object { "   " + ($_.Line -replace '^#\s*','').Trim() }
}

if ($Which -eq "all" -or $Which -eq "ref") {
    Invoke-Case -Tag "ref"     -DutPath "$sim/rtl/awb_ref.v" -Defines @("+define+ref","+define+NOFIFO")
}
if ($Which -eq "all" -or $Which -eq "fixed") {
    Invoke-Case -Tag "fixed"   -DutPath "$ProjectRoot/user_source/hdl_source/awb.v" -Defines @("+define+NOFIFO")
}
if ($Which -eq "all" -or $Which -eq "unfixed") {
    Invoke-Case -Tag "unfixed" -DutPath "$work/awb_d4unfixed.v" -Defines @("+define+D4UNFIXED")
}
Write-Host ""
Write-Host "日志: $work\<case>\sim.log"
