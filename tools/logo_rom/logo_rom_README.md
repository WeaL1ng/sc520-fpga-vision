# Logo ROM 改造说明（由 gen_logo_mif.py 自动生成）

## 0. 结论速览

> ⚠ **本节已按 2026-09-18 第三轮核验更正**（依据：`doc/analysis/核验与纠偏-2026-09-18第三轮.md` §2）。
> 早期版本写的"实测 ≈2,495 LUT6、净收益 −2,400 LUT6"**是从位密度反推的估算，不是 TD 的实测值**，
> 已作废。下表是各口径的**真实**报告值。

| 项 | 值 |
|---|---|
| 原始实现 | `anlogic_logo_rom.v` 稀疏 `case` 6,387 项 × 25 bit，**纯组合**（`always @(*)`） |
| 原始代价（TD **RTL 级**报告） | **38,479 个 gate**（注意是 gate，**不是 LUT**；该报告全设计 `#Total_luts` 仅 4,530） |
| 原始代价（TD **gate 级**） | 该模块**已从层级表中消失**（被吸收），无法单独计量 |
| 原始代价（**布局布线后**） | `u_hdmi_mixer` 整模块 **2,572 LUT**（其中 `u_anlogic_logo_rom` 单列 **54 LUT**） |
| **可信的差分口径** | lab1→lab3：`u_hdmi_mixer` **46 → 2,572 LUT（+2,526）**；全设计 slices **12,358 → 14,852（+2,494）**。<br>⚠ **这 2,526 LUT 中属于 Logo、属于手写点阵字库、属于像素率常量除法的各占多少，TD 的报告分不出来。** |
| 裁剪后有效区域 | x ∈ [7, 153)，y ∈ [34, 128)，共 146×94 |
| ROM 尺寸 | 深度 **13724** × 宽度 **8** bit = 109792 bit |
| **预计占用** | **6 个 ERAM 块**（器件共 108 块，lab3 已用 40 块） |
| 调色板 | 255 色，用 `logo_palette.vh` 里的 `case` 实现（≈96 LUT） |
| 颜色量化 | 579->255 色，最大误差 3/255、平均 0.08/255（肉眼不可分辨） |

**收益（修正后的表述）**

| 指标 | 改前（lab3 官方实测） | 目标 | 证据强度 |
|---|---|---|---|
| **`HDMI_PIXEL_CLK` 最差裕量** | **0.103 ns** | **≥ 1.5 ns** | ⭐ **确定**：组合链被 ERAM 同步读打断（综合阶段该域本是 WNS −1.296 ns） |
| DSP | 9/40 | **8/40** | **确定**：常量乘 160 从 `S_logo_y*LOGO_W` 移除 |
| ERAM | 40/108 | **46/108** | 确定：容量算术 |
| slices | 14,852 (70.00%) | **待实测** | ⚠ **必须用一次 P&R 确认，不要预设数字** |

**⇒ 首要目的是时序，不是省面积。**（早期版本文档把"省 2,400 LUT"当主收益，是错的。）

## 1. 在 TD 里生成 ROM IP

`Tools → IP Core Generator → Memories & Storage Elements → ROM`
（IP 库中的 `ROM` / 器件族 `F9F0D0P0` 即 PH1P 系列）
底层为 `PH1P_LOGIC_ERAM`，本工程已在用（demosaic 的行缓冲、AWB 延迟缓冲）。

> ⚠ **ERAM 的硬性约束（不是风格建议）**：PH1P ERAM 用户手册明确要求
> **"ERAM 的地址与数据输入必须与输入时钟同步"**，否则工具**不会对这些路径做时序分析**，
> **ERAM 内容可能不可预测地翻转**。
> **⇒ 所以"Output Register = OUTREG（同步读）"是必须的**，`NOREG` 不可用。

| 参数 | 值 | 说明 |
|---|---|---|
| Memory Type | **Single Port ROM** | 对应 `` `define SP_ROM `` |
| Width | **8** | 调色板索引位宽 |
| Depth | **13724** | 裁剪后的有效像素数 |
| Address Width | **14** | 自动推导 = ceil(log2(depth)) |
| Output Register | **OUTREG（默认，不可改）** | **同步读，1 拍延迟**；见上面的 ERAM 硬性约束 |
| Implement | **20K** | 不要选 20K(FAST) |
| Load Init File | 勾选，选 **`logo_pixel.mif`** | 与本说明同目录 |
| Port A Clock | HDMI 像素时钟（75 MHz） | |

> ⚠ 若 IP 向导要求深度为 2 的幂，请用 `--pow2` 重新生成脚本输出。
> ⚠ `.mif` 的 `DEPTH` 必须与 IP 里填的 Depth 完全一致，否则加载失败。
> ⚠ ERAM 结构参考：**1 个 ERAM slice = 2 × ERAM20K + 1 个 FIFO 控制器**，**ERAM20K 固定 20 Kbit**。

## 2. 地址与流水线（替换 hdmi_mixer.v 里的 Logo 逻辑）

```
// ── 几何（来自 logo_geom.vh）
//   屏幕有效区域: x ∈ [LOGO_X+7, LOGO_X+153), y ∈ [LOGO_Y+34, LOGO_Y+128)
//   rom_addr = dy * 146 + dx

// ① 行基址寄存器：每行只做一次乘法（原来每像素一次，还占了 1 个 DSP）
reg [14:0] row_base;                 // dy * LOGO_ROM_W
always @(posedge I_clk)
    if (I_line_start_gated)          // 在"进入有效区域行"的那一拍更新
        row_base <= dy_next * LOGO_ROM_W;   // 只在这时算乘法，常量 160 → 建议写成
                                            // (dy<<7)+(dy<<5)，彻底不用 DSP

// ② 逐像素：一次加法
wire in_logo = de_d2 && (x_d2 >= LOGO_X + LOGO_ROM_X0) && (x_d2 < LOGO_X + LOGO_ROM_X0 + LOGO_ROM_W)
                        && (y_d2 >= LOGO_Y + LOGO_ROM_Y0) && (y_d2 < LOGO_Y + LOGO_ROM_Y0 + LOGO_ROM_H);
wire [14:0] rom_addr = in_logo ? (row_base + (x_d2 - (LOGO_X + LOGO_ROM_X0))) : 15'd0;

// ③ 同步 ROM（IP，OUTREG → 1 拍延迟）
logo_pixel_rom u_logo_rom (.clka(I_clk), .addra(rom_addr), .doa(rom_idx));

// ④ 调色板 + 命中判决（第 2 拍）
always @(posedge I_clk) begin
    logo_hit_d <= in_logo && (rom_idx != 0);
    logo_col_d <= logo_palette(rom_idx);      // logo_palette.vh
end
```

**流水线对齐（务必核对）**
原来坐标用 `S_x_2d / S_y_2d`、数据用 `S_video_data_2d` 对齐 **2 拍**。
改造后 Logo 通路是 **2 级**（ROM OUTREG + 命中/调色板寄存器），
相对"组合式改写"其实只多 1 拍 —— 建议统一改为 **3 拍**（`_1d/_2d/_3d`），
把 `S_osd_hit / S_osd_color / 视频数据` 全部对齐到同一拍再进 `O_hdmi_data` 寄存器。
**验收方法**：自检模式下叠一个 1 像素棋盘或边框，确认 Logo 与背景无水平/垂直偏移。

## 3. 同时必须做的三件事（否则只解决一半）

1. **删掉像素率路径上的常量除法**
   `hdmi_mixer.v` 的 `S_pf_scale_x / 10'd24`、`/ 10'd15`、`/ 10'd8`：
   局部坐标只有 24 / 15 / 8 个取值 → 改成预计算查表（小 LUTRAM 或 `case`）。
2. **合并重复的 16 路 `case(S_pf_col)`**（原文件有 4 处几乎相同的 16 分支）
   → 抽成一个 `bit_select(S_pf_row_bits, S_pf_col)` 函数。
3. **别用 DSP 做乘 146**
   `S_logo_y * LOGO_W` 原来占掉 1 个 DSP（lab3 比 lab1 多 1 个 DSP）。
   改成行基址寄存器后，常量乘法用移位加法：146 = (dy<<7) + (dy<<4) + (dy<<1)。

## 4. 预期收益（**必须用一次 P&R 验证，不要预设面积数字**）

> ⚠ 下表已按第三轮核验修正。**面积一栏不写目标值**——早期版本写的"slices ≤12,500"没有依据。

| 指标 | 改造前（lab3 官方实测） | 目标 / 判据 | 强度 |
|---|---|---|---|
| **HDMI_PIXEL_CLK 最差裕量** | **0.103 ns** | **≥ 1.5 ns** | ⭐ 主目标，结构上必然改善 |
| HDMI_SERIAL_CLK 最差裕量 | 0.336 ns | ≥ 0.8 ns | 应一并纳入门禁 |
| DDR usr_clk 最差裕量 | 0.576 ns | 观察即可（新工具版本下已回到 2.311 ns） | 随拥塞缓解回升 |
| DSP | 9/40 | **8/40** | 确定（常量乘 146 移除） |
| ERAM | 40/108 | **46/108** | 确定（容量算术） |
| slices | 14,852 (70.00%) | **待实测** | ⚠ 不预设 |

**门禁命令（本工作区已有的回归工具）**

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\run_regression.ps1 `
  -ProjectRoot <工程路径> -Stage P1 -Tag "logo->ERAM" -TdRoot F:\al `
  -Targets @{ HDMI_PIXEL_CLK = 1.5; HDMI_SERIAL_CLK = 0.8 }
```

## 5. 生成产物清单

| 文件 | 用途 |
|---|---|
| `logo_pixel.mif` | ROM IP 的初始化文件 |
| `logo_palette.vh` | `function logo_palette`，索引 → 24bit RGB（`include` 到 hdmi_mixer.v） |
| `logo_geom.vh` | `LOGO_ROM_X0/Y0/W/H/DEPTH/ABITS/IDXBITS` localparam |
| `report.txt` | 颜色统计与量化误差（**含"面积收益待实测"的标注**） |
