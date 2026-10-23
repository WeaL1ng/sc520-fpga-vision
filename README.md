# 基于安路 FPGA 的实时数字图像处理系统（SC520CS 版）

> 2026 全国大学生嵌入式芯片与系统设计竞赛 · 安路赛道 · **选题二**
> 板卡 HX1P35A（FPGA `PH1P35MDG324`）· 摄像头 **SC520CS**（1280×720@60fps，RAW10，2-lane MIPI）

<!-- TOC -->
<details>
  <summary>目录</summary>

- [1. 这是什么](#1-这是什么)
- [2. 当前状态](#2-当前状态)
- [3. 功能清单](#3-功能清单)
- [4. 目录结构](#4-目录结构)
- [5. 快速开始](#5-快速开始)
- [6. 复现信息](#6-复现信息)
- [7. 设计要点与踩过的坑](#7-设计要点与踩过的坑)
- [8. 已知限制](#8-已知限制)
- [9. 资料与致谢](#9-资料与致谢)

</details>

---

## 1. 这是什么

一套跑在安路 PH1P35 上的**完整实时视频通路**：MIPI 摄像头采集 → ISP（BLC / Demosaic / AWB）→ 卡通化 → 颜色目标检测与包围框 → 运动目标检测 → OSD 叠加 → HDMI 720p 输出，并带**自动曝光闭环**。

整条链路是纯 RTL 实现（常量乘法全部用移位加法，不用 DSP 做常量乘），DDR 双缓冲，HDMI 由厂商 IP 驱动。

## 2. 当前状态

| 证据层 | 内容 | 状态 |
|---|---|---|
| L1 | 模块级 ModelSim 断言（模式循环 / 灰度 / 延迟 / Logo OSD / 卡通化 / 目标检测 12 场景 / AE 闭环） | ✅ 全部 PASS |
| L2 | Python 独立模型（字库往返、OSD 布局、亮度统计、tile 阈值判别力） | ✅ 全部 PASS |
| L3 | TD 报告独立解析（资源 / 各域 Fmax / 关键模块） | ⚠️ **时序违例，见下** |
| L4 | 上板目视 | ✅ 功能正常（SC520CS 采集、检测、OSD、AE 均工作） |

> ⚠️ **这是验证版，不是交付版。** SC520CS 的 720p60 把 MIPI 链路跑在 828 Mbps/Lane，字节时钟
> 103.5 MHz（SC500 是 60 MHz）。本设计 MIPI 域实测 **Fmax 103.413 MHz**，全局 **SWNS −0.010 ns**、
> **仅 1 个违例端点**（Hold 余量 +0.020 ns），最差路径集中在 `u_awb → u_target_detect_96` / `u_awb → u_luma_stats`。
> **板测功能正常**（画面、检测、OSD、AE 均工作），但时序不收敛，不能当交付版本。
> 曾尝试把 ISP 时钟域迁到 66.67 MHz 以换取零违例（构建成功、SWNS +1.06 ns），**上板满屏花屏**，
> 已回退 —— 详见 `bitstream/README.md` 的"版本演进"。

## 3. 功能清单

| 组 | 要求 | 实现 |
|---|---|---|
| 基础 | 视频采集与显示通路 | MIPI → DDR 双缓冲 → HDMI 720p60 |
| 基础 | 至少一种图像处理算法 | 卡通化（双边/量化）+ 灰度化 + Sobel |
| 基础 | 实时性 | 60 fps 恒定；延迟固定为 2 帧缓存 + 流水级数（不随场景变化） |
| 扩展 | 视频内容目标检测识别 | 颜色判据（Y/Cb/Cr 三判据）+ 8×8 tile 命中计数 |
| 扩展 | 叠加结果与文字 | OSD 八区域：框、坐标、诊断读数、状态条、模式号、Logo |
| 扩展 | 外部控制 | 按键切换模式 / AE 手动自动 / LED 与蜂鸣器 |
| 扩展 | 时序与资源 | 见第 6 节资源表 |
| 进阶 | 算法优化 | 全流水、常量乘用移位加法、DSP 只用于厂商 AWB |
| 进阶 | 动态跟踪与坐标叠加 | 包围框跟随 + 十进制坐标显示 |
| 进阶 | 低延迟 | 结构上固定 2 帧缓存 + 全流水；**不再自报延迟数字**（评委无法核验，改为用时序报告与结构分析佐证） |
| 进阶 | 运动目标检测 | `motion_detect.v`，背景按块自适应 + 腐蚀 + 连通计数 |

## 4. 目录结构

```
sc520/
├── rtl_vendor/anlogic_example/lab_ex4_all_features_SC500_720P/lab_ex4_all_features/
│   ├── user_source/hdl_source/     # 全部 RTL（含 uics520_cfg/ 传感器配置）
│   ├── user_source/{ip_source,constraints_source}/
│   └── td_project/                 # TD 工程（.al / .sdc / Runs/*.prj）
├── sim/                            # ModelSim 环境：TB、编译脚本、已编译的安路原语库
├── tools/                          # 构建 / 全量回归 / 报告校验 / 相机自检
├── doc/                            # 设计文档、分阶段报告、复盘、踩坑清单
├── SC520CS摄像头资料/               # 厂商数据手册、应用指南、SC520 例程
├── bitstream/                      # 本次位流 + TD 报告 + 烧写说明
└── README.md
```

> 工程目录名里的 `SC500_720P` 是厂商原始命名，**实际传感器配置已换成 SC520CS**（见
> `user_source/hdl_source/uics520_cfg/`）。保留原名是为了让 `tools/`、`sim/` 里的相对路径推导
> 与厂商例程一致，不用改一行脚本。

## 5. 快速开始

### 环境

| 项 | 路径/版本 |
|---|---|
| TD（Tang Dynasty） | `F:\al`（6.2.178840） |
| ModelSim | `F:\modelsim\modelsim_ase\win32aloem`（32 位 ASE） |
| Python | 3.x（脚本只用标准库） |

### 构建

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\build_fpga.ps1
# 只跑综合： -Stage syn ；只跑布线： -Stage phy
```

脚本会改 `settings.cfg` → 跑 syn → 跑 phy → 汇总报告。约 7~9 分钟。

### 回归

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\run_all_checks.ps1 -Fast
python tools\verify_td_reports.py
```

### 烧写

JTAG 在线配置（掉电失效，只适合验证）：

```powershell
# 在 td_project 目录下执行（bw_program.tcl 就在那里）
cd rtl_vendor\anlogic_example\lab_ex4_all_features_SC500_720P\lab_ex4_all_features\td_project
F:\al\bin\bw_commands_prompt.exe bw_program.tcl
```

或直接用 TD 的 BitWriter 图形界面选 `td_project/camera_to_dsi_display_Runs/phy_1/camera_to_dsi_display.bit`。

相机连不上时先跑自检：`powershell -File .\tools\check_jtag_cable.ps1`（会告诉你线缆绑的驱动对不对）。

## 6. 复现信息

| 项 | 值 |
|---|---|
| 位流 SHA256 | `05DD502A20712B50FFC4FD2AF8AA8EB0F18D277ADCE961C81FB534FB3B63C9DB` |
| 器件 | PH1P35MDG324，-3 速度等级 |
| slice | 16225 / 21216（**76.48%**） |
| LUT6 | 14320 / 21216（67.50%） |
| ERAM | 55 / 108（50.93%） |
| DSP | 8 / 40（20.00%） |
| IO | 63 / 160（39.38%） |
| 全局 SWNS | **−0.010 ns**（MIPI 域，仅 1 个违例端点） |

## 7. 设计要点与踩过的坑

完整清单见 [`doc/analysis/交接说明-20260927.md`](doc/analysis/交接说明-20260927.md)，这里只列最贵的几条：

1. **`case` 项的位宽必须与 `case` 表达式一致**。曾把 `4'd16` 写进 4 位 case，截断成 0，7 个赋值全成死代码，而"逐行核对"看不出问题。
2. **厂家参考设计里从没被例化过的模块，启用它等于首次集成**（`mipi_rx_error_detect`）。
3. **握手机制必须能超时**。"回读 == 目标 才继续"的设计，只要提交路径有一处不忠实就会静默冻结，症状只是"数值不再变化"。
4. **测试激励只覆盖一种结构，等于给某个设计打掩护**。P5 的 TB 总从帧第 0 拍开始，相位 bug 永不出现。
5. **`edit` 类工具会剥掉 UTF-8 BOM**，含中文的 `.ps1` 随即被 PowerShell 5.1 按 GBK 读而解析失败——本仓库带 `tools/_ensure_ps1_bom.py` 专门查这个。
6. **诊断能力不足时改判据 = 猜**。P5 的颜色判据连改三轮都是猜；只加了一个"探测点自动锁定"的观测量，一次拿到决定性数据。

## 8. 已知限制

- **时序未收敛**（−3.002 ns），见第 2 节。三条出路：给 `target_detect_96` / `luma_stats` 前端加流水；向厂商要 480 Mbps 的 SC520 寄存器表；或退到更低帧率。
- **`CB_MAX` 名存实亡**：实测臂章 Cb=120 越过该上限，判据① 实际不参与检测，靠判据③（比值）兜底。
- **哑光橙与肤色在暗光下 Cb/Cr 重合**（各差 3 LSB），任何矩形/线性判据都分不开，二者只能取一。
- **运动检测阈值未在真实场景整定**，只有合成噪声定值；画面最上/最左 8 像素带因腐蚀零填充报不出运动。
- **SPI-Flash 固化未做**：目前只有 JTAG 在线配置，掉电丢失。
- **AE 闭环参数按 SC520 重新取值**（AE 上限 1991、AG 上限 176 = 32×），但仍需在不同光照下实测收敛速度。

## 9. 资料与致谢

- 传感器与板卡资料：`SC520CS摄像头资料/`（厂商 Lab1/2/3 例程；**数据手册 PDF 不在本仓库**，见下）

> **关于厂商 PDF**：思特威的 SC520CS 数据手册/应用指南标注 "Company Confidential"，
> 公开仓库不再分发。本仓库只保留**厂商例程与自写的设计与分析文档**；
> 需要手册请向思特威官网或 FAE 索取（本工程用到的关键参数已摘录在 `doc/analysis/`）。
- 引脚分配：`doc/analysis/_extract/DX_HX1P35B引脚分配汇总.txt`
- 厂商参考设计：安路 `lab_ex1~4` 系列（MIPI / OSD / 全功能）、米联客 `lab_topic2_basic`
- 传感器配置表、`uics520_cfg/`、HDMI 发送 IP 均来自厂商提供，版权归原厂所有，仅用于本次竞赛。

本项目为竞赛参赛作品，**不对第三方厂商代码（安路 / 米联客 / SmartSens IP）主张任何许可**。
