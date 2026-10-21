# P1b 设计：Logo 组合查找表 → 同步 ERAM + 消除乘法器

> 日期：2026-09-20
> 工作目录：`_stage/lab_ex4_p1b_SC500_720P/lab_ex4_all_features`（**lab_ex4 原目录保持冻结**）
> 基线：P1a（`awb.v` D1 已修）+ `set sp 1` + `set_false_path`
> 基线实测：slice **16,466 (77.61%)** / DSP 3 / ERAM 43 / Setup **+10 ps** / Hold +20 ps / 0 违例

---

## 0. 为什么要做 P1b

P1b 的定位（`赛题二-分阶段实施方案.md` §v1.3 ②）：
**"主收益是时序（拿回 `HDMI_PIXEL_CLK` 裕量），不是省面积；面积收益必须 P&R 实测。"**

### 当前最差路径就是 Logo（实测，非推测）

从 `phy_1/camera_to_dsi_display_pr.timing` 的 slack=+0.010 ns 那条路径逐段量出：

| 段 | 累计 ns | 增量 | 内容 |
|---|---|---|---|
| 时钟网络 | 1.97 | 1.97 | PLL → GCLK → SCLK（扇出 336）|
| DSP 输入 | 2.57 | 0.60 | `mult0_syn_59` clk2q |
| **DSP 乘法** | 3.75 | **1.19** | `mult0_syn_60`（**`S_logo_y * 160`**，`hdmi_mixer.v:692`）|
| DSP 输出 | 4.29 | 0.54 | |
| 布线 | 5.29 | 0.99 | |
| **扇出网** | 6.65 | 1.36 | `add0_syn_2[6]`，**扇出 150** |
| **📌 组合 ROM 查找** | **12.75** | **6.10** | `u_anlogic_logo_rom/I_addr[6]` 起 **12 级 LUT**（L2→L6→L6→L6→L3→L5→L6→L6→L4）|
| 裕量 | | **0.010** | 总预算 13.3 ns |

⇒ **两块要动**：① 组合 ROM 查找 **6.1 ns**；② `y*160` 乘法器 **2.7 ns**。

### 根因

`anlogic_logo_rom.v` 是 **6,400 行的 `always @(*) case(I_addr)`**（1 个 always 块、0 个寄存器、无 `ram_style`）
⇒ 综合成**巨型组合 LUT 网**，直接把地址到像素的整条链压在同一个周期里。

---

## 1. 改动清单

| # | 改动 | 目的 | 风险 |
|---|---|---|---|
| **A** | 新增 `logo_rom_eram.v`（**已生成，vlog 0E/0W**） | 同步读 ROM，推断 ERAM，切断 6.1 ns 组合链 | 综合器若不推断 ERAM 会退化成寄存器阵列（更差）⇒ 必须用 P&R 报告核实 ERAM 数 |
| **B** | `hdmi_mixer.v`：Logo 地址改用 **`row_base` 寄存器**，去掉 `y*160`/`y*146` 乘法 | 消除 DSP 与扇出 150 | 行基址更新时机必须与像素对齐 |
| **C** | `hdmi_mixer.v`：Logo 区域改为**裁剪区**（146×94 @ 7,34），ROM 深度 13,724 | ROM 从 160×160 缩到 146×94，ERAM 省 | 坐标换算要 +X0/+Y0 |
| **D** | `hdmi_mixer.v`：OSD 结果（`S_osd_hit`/`S_osd_color`/`S_stat_color`/`S_mode_color`）**打一拍**再参与输出选择 | 把 OSD 组合逻辑从 `O_hdmi_data` 前面挪走 | **必须保持视频通路 2 级不变**（`risks.md` R-09） |
| **E** | 常量除法（`/24` `/15` `/8`）改查表、4 处重复 16 路 `case(S_pf_col)` 抽成函数 | 方案 §步骤 5，减组合深度 | 中（手写点阵逻辑复杂） |
| **F** | `.al` + 两个 `.prj` 注册 `logo_rom_eram.v`，移除 `anlogic_logo_rom.v` | 让新模块参与编译 | ← **上次就是这里被 GUI 回退，务必用 GUI 或脚本并复验** |

**本次先做 A/B/C/D（时序收益主体），E 视 A~D 的实测结果再定。**

---

## 2. 流水线对齐（关键，最容易出错的地方）

### 2.1 当前结构

```
S_x / S_y ──[2 拍]──► S_x_2d / S_y_2d ─┐
                                         ├─► 组合算 OSD（乘法 + ROM + 字库 + 状态条 + 模式数字）
I_video_rd_data ─[2 拍]─► S_video_data_2d ┘        │
                                                    ▼
                                            O_hdmi_data（寄存器）
```

问题：**OSD 的组合链与视频数据在同一拍结尾，全部挤进 13.3 ns。**

### 2.2 改后结构（OSD 结果打一拍）

```
S_x / S_y ──[2 拍]──► S_x_2d / S_y_2d
                          │
                          ├─ 第 N 拍：算 Logo 地址 + 发 ROM 读请求
                          │            （地址寄存器 row_base 与 S_x_2d 同拍）
                          ▼
                     第 N+1 拍：ROM 出索引 → 调色板 → 判定 hit/color
                                ↓ 打一拍
                     第 N+2 拍：O_hdmi_data 在 (S_osd_hit_r, S_osd_color_r, ...)
                                与 S_video_data_2d 之间做优先级选择

I_video_rd_data ─[2 拍]─► S_video_data_2d ─────────► 同上
```

⚠ **关键约束**：`S_video_data_2d` 的 **2 级延迟必须原样保留**
（`risks.md` R-09：新增的叠加逻辑必须与既有 2 级延迟的 `S_video_data_2d` 对齐，
**不得改变该 2 级延迟结构**）。

⇒ 正确做法是：**把 OSD 的判定结果（hit + color）打一拍，而不是再去延迟视频数据**。
这样：
- 视频通路：2 级不变 ✅
- 坐标通路：2 级不变 ✅
- OSD 结果：由"组合"变成"寄存"，与 `S_video_data_2d` 同拍参与选择 ✅

### 2.3 ROM 的额外一拍如何消化

新 ROM 比旧 ROM **多 1 拍**（旧：组合；新：`addr_reg` → `r_idx`）。
把这 1 拍吸收进"OSD 结果打一拍"里 —— 即：

```
第 N 拍  : 由 S_x_2d/S_y_2d 算出 rom_addr，写入 addr_reg
第 N+1 拍: ROM 输出索引 → 查调色板 → 与其他 OSD 源合并 → 打拍写入 S_osd_*_r
第 N+2 拍: O_hdmi_data 用 S_osd_*_r 做选择
```

而 `S_video_data_2d` 从 `I_video_rd_data` 起算也是第 N+2 拍可用
（因为 `S_x_2d` 与 `S_video_data_2d` 同拍）⇒ **天然对齐，不需要额外延迟视频**。

---

## 3. Logo 地址计算（去掉乘法器）

### 3.1 裁剪区几何（来自 `logo_geom.vh`）

```
屏幕坐标 (LOGO_X + LOGO_ROM_X0 + dx,  LOGO_Y + LOGO_ROM_Y0 + dy)
  LOGO_X = 0, LOGO_Y = 0
  LOGO_ROM_X0 = 7,   LOGO_ROM_Y0 = 34
  LOGO_ROM_W  = 146, LOGO_ROM_H  = 94
  rom_addr = dy * 146 + dx        （0 .. 13723）
```

### 3.2 用行基址寄存器替代乘法

```verilog
// dy = S_y_2d - 34 ;  dx = S_x_2d - 7
// 只在进入 Logo 区第一行那一拍更新 row_base，之后每行加 146
if (进入 Logo 区第一行) row_base <= 0;
else if (在 Logo 区 && 新行开始) row_base <= row_base + 146;
rom_addr <= row_base + dx;
```

- **146 = 128 + 16 + 2** ⇒ 若不用 DSP，可写成 `(dy<<7)+(dy<<4)+(dy<<1)`（纯移位加法）
- 因为 `rom_addr` 现在接的是**寄存器输入**（ERAM 地址寄存器），
  这条链**不再与最终输出寄存器抢同一个周期** ⇒ 即使保留 `dy*146` 也无害
- **保守起见**：先用 `row_base` 累加（无乘法），彻底消除 DSP 与扇出 150

---

## 4. 验收口径

| # | 检查项 | 判据 |
|---|---|---|
| 1 | **ERAM 数** | 应从 43 增到 **≈49**（+6 块）。若没增加 ⇒ 综合器**没推断出 ERAM**，需回退到 IP 方式 |
| 2 | **HDMI_PIXEL_CLK 域 SWNS** | 目标 **≥ 1.5 ns**（基线仅 +0.010 ns） |
| 3 | **全设计 0 违例** | `NUM_FEPS = 0`（Setup + Hold） |
| 4 | **slice** | 不劣于基线 16,466；期望下降（组合 ROM 变 ERAM） |
| 5 | **DSP** | 不增（应因去掉 `y*160` 而**减 1**：3 → 2） |
| 6 | **Logo 位置无偏移** | 上板比对：Logo 应仍在左上角，与文字/状态条相对位置不变 |
| 7 | **视频通路 2 级未变** | 代码审查 + 上板无水平/垂直偏移（`risks.md` R-09） |
| 8 | 综合无 black box | `run.log` 里 `black box` 计数 = 0 |

---

## 5. 回滚方式（lab_ex4 原目录已冻结）

原目录 `rtl_vendor/anlogic_example/lab_ex4_all_features_SC500_720P` **完全未被本次改动触碰**：

| 要回到什么 | 怎么做 |
|---|---|
| **P1a 状态（上板基线）** | 原目录就是 P1a。bitstream 在 `phy_1/camera_to_dsi_display.bit`（16:19:33，1,789,539 B） |
| **P1a 的 RTL 备份** | `_stage/lab4_p1a_fixed_20260920_162021/awb.v.P1a_D1fixed` |
| **P1a 的完整报告** | `_stage/lab4_p1a_fixed_20260920_162021/`（`route_flow.status` / `_phy.area` / `_pr.timing`） |
| **P1a 的配置** | `.sdc`（含 `set_false_path`）+ `phy_1/settings.cfg`（含 `set sp 1`）均已备份在同目录 |
| **放弃 P1b** | 直接删 `_stage/lab_ex4_p1b_SC500_720P/`，什么都回到原样 |

⚠ **唯一会被 P1b 修改的原目录外文件**：无。`tools/gen_logo_rom_v.py` 是新文件，
`tools/logo_rom/` 是只读素材（生成物写到副本里）。

---

## 6. 已知风险

| # | 风险 | 缓解 |
|---|---|---|
| R1 | **综合器不推断 ERAM** ⇒ 退化成寄存器阵列，面积暴涨、时序不一定好 | 先跑一次综合，**看 ERAM 数**。若没涨就用 TD IP Core Generator 生成 ROM IP（方案原文做法） |
| R2 | **`.al` 编译列表被 GUI 回退**（本会话已发生 3 次） | 改完立刻复验三处文件；只用 GUI 的 Add Source，或在 GUI 关闭时用脚本 |
| R3 | **Logo 位置偏移** | 用 `logo_geom.vh` 的 X0/Y0 精确定位；上板前先在仿真或用差分图核对 |
| R4 | **手写点阵字库那条链（改动 E）很复杂** | 本次先不做 E。若 D 之后仍不达标，再单独评估 |
| R5 | **ROM 深度 13,724 与 mif 的 DEPTH 必须一致** | 生成器已按同一 depth 产出，二者同源 |
