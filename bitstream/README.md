# 位流与构建报告（SC520CS 验证版）

> **这是验证版，不是交付版。** 板测功能正常，但时序未收敛，详见下面"已知问题"。

## 文件

| 文件 | 说明 |
|---|---|
| `camera_to_dsi_display.bit` | FPGA 原始位流，1,789,539 B |
| `camera_to_dsi_display_compress.bit` | BitWriter 用的压缩位流 |
| `camera_to_dsi_display_phy.area` | 布线后资源报告 |
| `camera_to_dsi_display_pr.timing` | 布线后时序报告 |
| `camera_to_dsi_display_chk.timing` | 时序检查报告 |
| `camera_to_dsi_display.sdc` | 本次构建使用的约束 |

## 复现

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build_fpga.ps1
python tools\verify_td_reports.py
```

位流 SHA256：

```
05DD502A20712B50FFC4FD2AF8AA8EB0F18D277ADCE961C81FB534FB3B63C9DB
```

> 注意：TD 的 bitgen 会往文件头写构建日期，所以**同样的 RTL 重新构建出的位流 SHA 会变**。
> 判断"内容是否等价"要比对头部 `Global CRC` 行；RTL 不变时该值一致。

## 已知问题：时序违例

| 时钟域 | 约束 | 实测 Fmax | 状态 |
|---|---|---|---|
| `MIPI_RX_BYTE_CLK` | 9.660 ns（103.5 MHz） | **78.976 MHz**（12.662 ns） | ❌ 差 3.0 ns |
| `HDMI_PIXEL_CLK` | 13.333 ns | 75.620 MHz | ⚠️ 余量 0.8% |
| `usr_clk`（DDR） | 15.000 ns | 67.222 MHz | ⚠️ 余量 0.8% |

- 全局 **SWNS −3.002 ns**，**497 个违例端点**
- 最差路径：`u_awb/mult6_syn_165` → `u_target_detect_96/tx_min_reg[0]`，12.403 ns / 16 级逻辑（ADDER×6），判型为**逻辑深度型**（cell 61%）
- 次差：`u_awb` → `u_luma_stats/S_sum`，12.4 ns / 14 级

**根因**：SC520CS 的 720p60 把 MIPI 跑在 828 Mbps/Lane（SC500 是 480），字节时钟 60 → 103.5 MHz，
同一套 ISP 逻辑的时间预算从 16.67 ns 压到 9.66 ns。

**为什么仍然能跑**：板测（JTAG 在线配置）图像、检测、OSD、AE 均正常。违例集中在
AWB→检测/亮度统计这一条链上，实际工作条件下没有显性失效——但这是余量为负，
温度/批次变化就可能出问题，**不能作为交付版本**。

## 三条出路

1. **给 `target_detect_96` / `luma_stats` 前端加流水**（逻辑深度型，对症），把 12.4 ns 压到 9.66 ns 以内；会改 P3 的延迟数值，OSD 的 `LATENCY` 要同步更新，L1 回归要重跑。
2. **向厂商要 SC520 720p60 但 MIPI 走 480 Mbps 的寄存器表**。速率由表里 `0x36e9..0x36ed` 的 PLL 寄存器决定；降下来后 MIPI 域回到 60 MHz，本设计零改动即可收敛。
3. 退到更低帧率（如有对应寄存器表）。

## 烧写与掉电

`-mode jtag` 是**在线配置，掉电即失效**。断电后需重新烧写（或用 SPI-Flash 固化，那一步尚未做）。

烧写命令（在 `td_project` 目录下执行，`bw_program.tcl` 就在该目录）：

```powershell
F:\al\bin\bw_commands_prompt.exe bw_program.tcl
```

或 TD → BitWriter → 选上面的 `.bit` → `-mode jtag -spd 7`。

线缆连不上时先跑：`powershell -File .\tools\check_jtag_cable.ps1`
