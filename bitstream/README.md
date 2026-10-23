# 位流与构建报告

> **状态：已固化进 SPI-Flash，上电自动运行（2026-10-23）**
> 时序：**全局 SWNS −0.010 ns、仅 1 个违例端点**（Hold 余量 +0.020 ns），实质收敛。
> 板测：图像 / 卡通 / 目标检测 / 运动检测 / AE 全部正常。

## 文件

| 文件 | 说明 |
|---|---|
| `camera_to_dsi_display.bit` | FPGA 原始位流，1,789,539 B |
| `camera_to_dsi_display_compress.bit` | BitWriter 用的压缩位流 |
| `camera_to_dsi_display_phy.area` | 布线后资源报告 |
| `camera_to_dsi_display_pr.timing` | 布线后时序报告 |
| `camera_to_dsi_display_chk.timing` | 时序检查报告 |
| `camera_to_dsi_display.sdc` | 本次构建使用的约束 |

SHA256（`.bit`）：

```
574259FC2F36B714DF7F390C1EA36E0342F96D152F955E160D31CA81B8C7C34D
```

> TD 的 bitgen 会往文件头写构建日期，所以**同样的 RTL 重新构建出的 SHA 会变**。
> 判断"内容是否等价"要比对头部 `Global CRC` 行；RTL 不变时该值一致。

## 资源与时序（2026-10-23 21:02 构建）

| 资源 | 已用 | 总量 | 占用 |
|---|---|---|---|
| Slice | 15,892 | 21,216 | 74.91% |
| LUT6 | 13,825 | 21,216 | 65.16% |
| 寄存器 | 15,262 | 42,432 | 35.97% |
| ERAM | 55 | 108 | 50.93% |
| DSP | 8 / 40（全部来自厂商 AWB） | 40 | 20.00% |

| 时钟域 | 约束 | 实测 Fmax | 余量 |
|---|---|---|---|
| `MIPI_RX_BYTE_CLK` | 103.52 MHz（9.66 ns） | **103.413 MHz** | **−0.010 ns**（1 个端点） |
| `usr_clk`（DDR） | 66.667 MHz | 81.833 MHz | +22.7% |
| `HDMI_PIXEL_CLK` | 75.002 MHz | 75.855 MHz | +1.1% |
| `HDMI_SERIAL_CLK` | 375.094 MHz | 697.350 MHz | +85.9% |
| Hold | — | **HWNS +0.020 ns** | 无违例 |

## 复现

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build_fpga.ps1
python tools\verify_td_reports.py
python tools\_timing_classify.py <pr.timing 路径>   # 按模块归类违例路径
```

## 固化（上电即运行，赛题硬性要求）

本工程已用 BitWriter 的 SPI-Flash 编程模式烧写：

```powershell
# 在 td_project 目录下
F:\al\bin\bw_commands_prompt.exe bw_spi_v4.tcl
# 其中：download -bit ... -mode program_spi -v -spd 7 -cable 0 -flashsize 128
```

日志确认：`SPI Flash ID is: c8`（GigaDevice，128 Mbit）→ `Programming SPI Flash QE to enable
quad mode`（与 `.al` 的 `boot_mode = mspix4` 匹配）→ `sector erase` → `Page program and verify`。

> ⚠️ 经验：如果 BitWriter 的 GUI 窗口还开着（`bw` 进程残留），CLI 再烧 Flash 会卡在
> `Page program and verify` 不动。**烧之前先关掉 GUI、确认没有残留 `bw` 进程。**

## 版本演进（含一次失败尝试，保留记录以免重蹈）

| 版本 | 改动 | 时序 | 上板结果 |
|---|---|---|---|
| **v1** `05DD502A` | SC500 → SC520CS 全套配置移植 | SWNS **−3.002 ns** / 497 端点 | ✅ 功能正常 |
| **v2** `EAD7CAB2` | ISP 时钟域迁到 `usr_clk` 66.67 MHz + 双时钟异步 FIFO | SWNS **+1.062 ns** / **0 端点** | ❌ **满屏花屏** |
| **v3** `47B42CF1` | 回退 v2；保留三处输入流水 + 停用 LATENCY | SWNS **−2.220 ns** / 156 端点 | ✅ 功能正常 |
| **v4** `574259FC` | 给 AWB 的 5 个消费者各加本地输入寄存器（**拆分扇出**） | SWNS **−0.010 ns** / **1 端点** | ✅ 功能正常，**已固化** |

### v2 为什么失败（未完全定位，供后来者参考）

v2 是唯一"靠换时钟域"让时序收敛的方案，但上板满屏花屏。已排除：FIFO 读协议与 IP 规范一致、
按行突发估算不会溢出、TD 报告零违例、传感器配置与 v1 相同。怀疑跨域后帧相位与 `video_in`
内部 FIFO 复位脉冲的关系改变。**结论：功能优先，不可用功能换余量。**

### v4 是怎么做到的（关键经验）

v3 的 156 个违例端点全部落在 `u_awb → 各分支` 这一段。把它们按起点/终点归类后发现：
**net（布线）占最差路径的 35~38%**，而逻辑级数只有 10~15 ⇒ 瓶颈不是逻辑深度，是**扇出**：
AWB 的一个输出寄存器同时驱动 5 个消费者（灰度 / 卡通 / 目标检测 / 运动检测 / 亮度统计）。

修法不是继续加流水，而是**给每个消费者在它自己输入端加一组捕获寄存器**——
一个网络只驱动一组寄存器，布线自然散开。结果 156 → 1 个端点，而 LUT 反而少了 142 个
（综合器做了寄存器共享）。

剩余那 1 个端点是 **10 皮秒**，在 `motion_detect` 的腐蚀加法链上；再拆要改块配对逻辑
（偶/奇拍配对），收益与风险不成比例，**主动停手**并如实记录。

## 烧写（开发阶段，掉电失效）

```powershell
F:\al\bin\bw_commands_prompt.exe bw_program.tcl     # -mode jtag
```

线缆连不上时先跑：`powershell -File .\tools\check_jtag_cable.ps1`
