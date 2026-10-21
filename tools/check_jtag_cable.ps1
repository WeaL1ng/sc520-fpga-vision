# ============================================================
#  check_jtag_cable.ps1 --- 只读自检：安路 USB-JTAG 线缆的驱动绑定是否正确
#
#  2026-10-21 的故障：TD 的 BitWriter（bw.exe）报
#      PRG-8000 ERROR: Connect server failed.
#  真相是它拉起的 hwserver 立刻死在：
#      Open device vid=0x0403 pid=0x6042, id=0
#      Error @ mpsse.cpp:90 : usb_open() failed
#  hwserver 用 libftdi + libusb，而线缆被绑在 FTDI 原厂 CDM 驱动
#  （oem143.inf / ftdibus 2.12.36.20）上 ⇒ libusb 打不开 ⇒ hwserver 退出
#  ⇒ bw.exe 连不上 127.0.0.1:5555 ⇒ TD 报"无法连接板子"。
#  hwserver 自己带着这句判词：
#      unable to claim usb device. Make sure the default FTDI driver is not in use
#
#  修法（需管理员）：UsbDriverTool.exe 把 "USB Serial Converter A" 改装 WinUSB(libusb)，
#  然后拔插一次 USB。工具在：
#    E:\siti2\软件\1_安路工具和软件\新版TD驱动PH1P35使用方法\
#      安路JTAG驱动安装_固件\UsbDriverTool\UsbDriverTool.exe
#
#  两个实现上的坑（都实测过）：
#   * 不要用 Get-PnpDeviceProperty —— 本机单次调用约 15 s，4 个属性 × 2 个接口
#     就能拖过 2 分钟超时，看起来像"卡死"。改用原生 pnputil，108 ms 出结果。
#   * 不要在脚本里拉 hwserver —— 子进程会继承输出句柄，调用方的管道一直挂着。
#
#  用法：
#     powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\check_jtag_cable.ps1
# ============================================================
[CmdletBinding()]
param([int]$Port = 5555)

$ErrorActionPreference = 'Continue'

Write-Host ''
Write-Host ('=' * 70)
Write-Host ' 1. 线缆枚举与驱动绑定（pnputil）'
Write-Host ('=' * 70)

# 注意：别去改 [Console]::OutputEncoding 想把 pnputil 的中文转正 ——
# 实测会把输出弄乱到解析失败（块首变成 "Microsoft"）。厂商名里的中文乱码无害，
# 判定只用驱动的 inf 名与 "FTDI" 这个 ASCII 厂商名。
$enum = pnputil /enum-devices /connected /drivers 2>&1 | Out-String
# pnputil 的每块以 "> Instance ID:" 开头（注意有个 "> " 前缀）
$blocks = $enum -split "(?m)^>?\s*Instance ID:\s*" | Where-Object { $_ -match 'VID_0403&PID_6042|VID_336C&PID_100' }

$bad = $false
if (-not $blocks) {
    Write-Host '  [NG] 没有发现安路线缆（0403:6042 或 336C:100x）'
    Write-Host '       检查：USB 线是否插好、板子是否上电、是否换了别的 USB 口'
    $bad = $true
} else {
    foreach ($b in $blocks) {
        $grab = {
            param($re)
            $m = [regex]::Match($b, $re)
            if ($m.Success) { $m.Groups[1].Value.Trim() } else { '' }
        }
        $inst = & $grab '^\s*(\S+)'
        $desc = & $grab '(?m)^\s*Device Description:\s*(.+)$'
        $mfg  = & $grab '(?m)^\s*Manufacturer Name:\s*(.+)$'
        $drv  = & $grab '(?m)^\s*Driver Name:\s*(.+)$'
        $cls  = & $grab '(?m)^\s*Class Name:\s*(.+)$'
        Write-Host ("  {0}" -f $inst)
        Write-Host ("    名称={0}  厂商={1}  驱动={2}  类={3}" -f $desc, $mfg, $drv, $cls)

        if ($inst -match '&MI_01' -or $inst -match '^FTDIBUS') {
            # 接口 1 = FT2232H 的 B 通道，EEPROM 里就是 VCP，给 UART 用，属正常
            Write-Host '    [OK] B 通道（UART），保持 FTDI VCP 驱动是对的'
        } elseif ($inst -notmatch '&MI_') {
            # 复合设备的父节点（usbccgp），不代表任何通道，不参与判定
            Write-Host '    [--] 复合设备父节点，不参与判定；看上面 MI_00/MI_01 两个通道'
        } elseif ($drv -match 'ftdibus|ftdiport|usbser' -or $mfg -match 'FTDI') {
            Write-Host '    [NG] A 通道绑在 FTDI 原厂驱动上 —— libusb 打不开，TD 一定连不上'
            $bad = $true
        } else {
            Write-Host '    [OK] A 通道不是 FTDI 原厂驱动，libusb 可用'
        }
    }
}

Write-Host ''
Write-Host ('=' * 70)
Write-Host ' 2. hwserver 进程与端口（netstat）'
Write-Host ('=' * 70)

$procs = @(Get-Process hwserver -ErrorAction SilentlyContinue)
if ($procs.Count) {
    $procs | ForEach-Object { Write-Host ("  hwserver pid={0} 启动于 {1}" -f $_.Id, $_.StartTime) }
} else {
    Write-Host '  hwserver 未运行（正常，BitWriter 需要时才拉起）'
}

$listen = @(netstat -ano | Select-String -Pattern (":{0}\s" -f $Port))
if ($listen.Count) {
    $listen | ForEach-Object { Write-Host ('  ' + $_.Line.Trim()) }
} else {
    Write-Host ("  端口 {0}/{1} 空闲" -f $Port, ($Port + 1))
}

Write-Host ''
Write-Host ('=' * 70)
if ($bad) {
    Write-Host ' 判定：[NG] 驱动绑定不对，TD 连不上线缆'
    Write-Host ''
    Write-Host ' 修法（需管理员）：'
    Write-Host '   1) 拔插一次 USB，确保线缆在位'
    Write-Host '   2) 以管理员身份运行 UsbDriverTool.exe'
    Write-Host '      （软件\1_安路工具和软件\新版TD驱动PH1P35使用方法\安路JTAG驱动安装_固件\UsbDriverTool\）'
    Write-Host '   3) 选中 "USB Serial Converter A"，右键换成 WinUSB(libusb) 驱动'
    Write-Host '   4) 再拔插一次 USB；A 口不应再出现在"端口(COM 和 LPT)"下'
    Write-Host '   5) 重跑本脚本，两个接口都应显示 [OK]'
    exit 1
}
Write-Host ' 判定：[OK] 线缆绑定正常，TD 的 Programmer 应该能连上'
exit 0
