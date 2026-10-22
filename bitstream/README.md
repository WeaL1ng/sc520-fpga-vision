# 位流与构建报告

> **状态：板测通过（2026-10-22）** —— 图像、模式切换、目标检测、OSD、AE 均正常。
> **但时序仍有违例**（−2.220 ns），是"功能优先"下的验证版，不是零违例的交付版。

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
47B42CF119B81EC62A68F2DF4E4D158346049DB4B3763ED7BCADBC5362D5AB9F
```

> TD 的 bitgen 会往文件头写构建日期，所以**同样的 RTL 重新构建出的 SHA 会变**。
> 判断"内容是否等价"要比对头部 `Global CRC` 行；RTL 不变时该值一致。

## 复现

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build_fpga.ps1
python tools\verify_td_reports.py
```

## 时序现状（本版仍然违例）

| 时钟域 | 约束 | 实测 Fmax | 状态 |
|---|---|---|---|
| `MIPI_RX_BYTE_CLK` | 9.660 ns（103.5 MHz） | **84.175 MHz** | ❌ 差 2.2 ns |
| `usr_clk`（DDR） | 15.000 ns（66.67 MHz） | 92.285 MHz | ✅ |
| `HDMI_PIXEL_CLK` | 13.333 ns（75 MHz） | 76.051 MHz | ⚠️ 余量 1.4% |
| `pll_clk_24m` | 42.0 ns（23.81 MHz） | 64.754 MHz | ✅ |

- 全局 **SWNS −2.220 ns**，**156 个违例端点**
- 最差路径集中在 `u_awb → u_target_detect_96` 与 `u_awb → u_luma_stats`
  （12.4 ns / 14~16 级、ADDER 多），属**逻辑深度型**
- 已对这三处（另加 `motion_detect` 输入）各加了一级流水：497 → 156 个端点，Fmax 78.976 → 84.175 MHz；
  再往下加流水**边际收益归零甚至倒退**（85.1 → 84.2），瓶颈已变成布线拥塞（net 占 35~38%）

**根因**：SC520CS 的 720p60 把 MIPI 跑在 828 Mbps/Lane（SC500CS 是 480），
字节时钟 60 → 103.5 MHz，同一套 ISP 逻辑的时间预算从 16.67 ns 压到 9.66 ns。

## 版本演进（含一次失败尝试，保留记录以免重蹈）

| 版本 | 改动 | 时序 | 上板结果 |
|---|---|---|---|
| **v1** `05DD502A` | SC500 → SC520CS 全套配置移植 | SWNS **−3.002 ns** / 497 端点 | ✅ 图像与功能正常 |
| **v2** `EAD7CAB2` | ISP 时钟域迁到 `usr_clk` 66.67 MHz，MIPI 与 ISP 间加双时钟异步 FIFO | SWNS **+1.062 ns** / **0 端点** | ❌ **满屏花屏** |
| **v3** `47B42CF1` | 回退 v2；保留三处输入流水 + 停用 LATENCY | SWNS **−2.220 ns** / 156 端点 | ✅ **图像与功能正常** |

### v2 为什么失败（未完全定位，供后来者参考）

v2 是唯一让时序收敛（零违例）的方案，但上板满屏花屏。已排除的原因：

- **FIFO 读协议**：与 IP 规范一致 —— `soft_fifo_al` 的 `valid = re_r1 & !empty_r1`
  （`soft_fifo_al_4057d6b76aa6.v` 第 185~197 行），读侧也按此把 `tvalid` 打了一拍；
- **吞吐**：按行突发估算，FIFO 峰值占用约 114 字 ≪ 512 深；
- **时序**：TD 报告零违例；
- **传感器配置**：v1 与 v2 用的是同一套 `uics520_cfg`，v1 图像正常。

怀疑方向（未验证）：跨域后帧相位与 `video_in` 内部 FIFO 的复位脉冲（`S_fifo_rst`）关系改变，
或 AWB 内部 `w155` FIFO 的突发吞吐边界。

**结论**：功能优先。v1/v3 在 −2~−3 ns 违例下能稳定出图，说明本设计对时序余量不敏感；
把违例如实写进报告，而不是拿功能去换余量。**若将来重试时钟域迁移，必须先在板子上验证
视频不失真，再谈时序收益。**

## 烧写

JTAG 在线配置（掉电失效）：

```powershell
# 在 td_project 目录下执行
F:\al\bin\bw_commands_prompt.exe bw_program.tcl
```

或 TD → BitWriter → 选上面的 `.bit` → `-mode jtag -spd 7`。

> ⚠️ **SPI-Flash 固化尚未完成**（赛题硬性要求"上电即可运行"）。步骤见仓库外的
> `提交材料/06_P0-SPI固化步骤.md`。

线缆连不上时先跑：`powershell -File .\tools\check_jtag_cable.ps1`
