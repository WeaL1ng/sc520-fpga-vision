# TD IDE (GUI) 操作清单 —— lab4 整合工程

> 面向：在 TangDynasty 图形界面里自己跑构建
> 背景：2026-09-19 19:36 的一次 GUI `reset_run` 把 4 个新文件从编译列表里冲掉了，
> 综合随即报 4 条 `HDL-8007 ... is a black box` 并失败。
> 本清单确保**不再重蹈**，并给出跑通后的验收数字。

---

## 0. 先做一件事：让 GUI 重新读工程

**这是最重要的一步。**

刚才那次黑盒失败，根源是 **GUI 内存里的文件列表是旧的**（没有那 4 个文件），
它一执行 `reset_run` 就把磁盘上正确的列表覆盖回旧的。

所以：

1. **不要再点 "Reset Runs"**（除非你确认编译列表里已有那 4 个文件）。
2. **关闭当前工程再重新打开**，或直接**关掉 TD IDE 重新启动并打开**：
   ```
   ...\lab_ex4_all_features_SC500_720P\lab_ex4_all_features\td_project\camera_to_dsi_display.al
   ```
   目的是让 GUI 从磁盘重新载入文件列表。

---

## 1. 检查编译列表里有没有这 4 个文件（关键校验）

在左侧 **Design Hierarchy / Sources** 面板找到 **Verilog** 分组，展开，
确认以下 4 项**存在**（相对 `user_source/hdl_source/`）：

| # | 文件 | 磁盘绝对路径 |
|---|---|---|
| 1 | `key_mode_ctrl.v` | `<lab>\user_source\hdl_source\key_mode_ctrl.v` |
| 2 | `anlogic_logo_rom.v` | `<lab>\user_source\hdl_source\anlogic_logo_rom.v` |
| 3 | `osd_char_lib.v` | `<lab>\user_source\hdl_source\osd_char_lib.v` |
| 4 | `isp/edge_detect_96.v` | `<lab>\user_source\hdl_source\isp\edge_detect_96.v` |

> `<lab>` = `...\lab_ex4_all_features_SC500_720P\lab_ex4_all_features`

磁盘上**已经注册好了**（2026-09-19 19:38:13 写入，三处文件各 4/4，CompileOrder 51–54）。
所以**如果重新打开工程后这 4 项已经在列表里，第 2 步可以跳过。**

---

## 2. 如果 GUI 里**没有**这 4 个文件：用 Add Source 手动加

**务必用 GUI 菜单加，不要靠"添加整个目录"**（工程里有 8 组重名 module，
目录通配会立刻触发重复定义错误 —— 见 `doc/arch/risks.md` R-03）。

1. 菜单 **Project → Add Source**（或用 Sources 面板的 **+ / Add Files** 按钮）
2. 依次添加（**按这个顺序**，让 CompileOrder 递增）：
   ```
   1) <lab>\user_source\hdl_source\key_mode_ctrl.v
   2) <lab>\user_source\hdl_source\anlogic_logo_rom.v
   3) <lab>\user_source\hdl_source\osd_char_lib.v
   4) <lab>\user_source\hdl_source\isp\edge_detect_96.v
   ```
3. 若弹出 "copy files into project / 复制到工程目录" 之类选项，**选"不复制 / 保持原路径"**
   （4 个文件都已在 `hdl_source/` 下，不应再复制一份）。
4. 确认 4 项都出现在 **Verilog** 分组内（不是 SystemVerilog、不是 IP）。
5. **保存工程**（Ctrl+S / Project → Save）。

> **验证是否真的生效**：打开
> `<lab>\td_project\camera_to_dsi_display.al`（记事本即可），
> 搜索 `key_mode_ctrl`，应能找到 `<File Path="../../user_source/hdl_source/key_mode_ctrl.v">`。
> 找不到 ⇒ GUI 没保存成功，回到第 1 步。

---

## 3. 检查时序约束文件（`set_false_path` 是否在位）

打开 `<lab>\td_project\camera_to_dsi_display.sdc`，**末尾**应有一行：

```tcl
set_false_path -from [get_clocks {pll_clk_24m}] -to [get_clocks {HDMI_PIXEL_CLK}]
```

- ✅ 在：不用管。
- ❌ 不在：说明被 GUI 覆盖过。把这一行加回去（**必须纯 ASCII、不要写中文注释**，
  TD 的 Tcl 外壳对非 ASCII 不安全）。

**为什么必须有这一行**：`set_clock_groups` 把 `pll_clk_24m` 与 `HDMI_PIXEL_CLK`
放进了同一同步组，导致 STA 去比较两个无固定相位关系的 PLL 输出抽头，
挑中只差 **0.653 ns** 的一对边沿，而数据路径本身就有 **0.529 ns**：
```
Path Group     : pll_clk_24m -> HDMI_PIXEL_CLK
Slack          : -0.111 ns   (2 Viol Endpoints / 3 Total)
Logic Level    : 0           <- 零级逻辑，说明是约束问题而不是逻辑慢
Data Path Delay: 0.529 ns
Budget         : 0.653 ns
```
加上这一行后：Setup WNS 由 **−111 ps / 2 FEPs → +115 ps / 0 FEPs**。
它**只**关掉这一条跨域检查，同域路径（`pll_clk_24m→pll_clk_24m`、
`HDMI_PIXEL_CLK→HDMI_PIXEL_CLK`、`HDMI_PIXEL_CLK→HDMI_SERIAL_CLK`）仍全部分析。

---

## 4. 跑综合（Synthesis）

1. 在 Runs 面板选中 **syn_1**，点 **Run**（或 Run Synthesis）。
2. **期望**：无 `HDL-8007 black box` 错误，综合成功。
3. **必查**（这一步是判断"新文件真的被编译了"的唯一凭证）：
   ```
   <lab>\td_project\camera_to_dsi_display_Runs\syn_1\run.log
   ```
   搜索 `black box` → 应为 **0 条**。
   同时搜索 `key_mode_ctrl` / `edge_detect_96` / `anlogic_logo_rom` / `osd_char_lib`
   → 每个都应出现（说明它们被读入并展开了）。

> ⚠ **如果又出现 4 条 black box** ⇒ 编译列表又没生效，回到第 1、2 步。
> **不要**在这种情况下继续跑 P&R —— 会白跑 15 分钟且必然失败。

---

## 5. ⚠ 在跑 P&R **之前**：补 `set sp 1`（本清单里唯一需要手改文件的地方）

**这一步不做，第 3 步的 `set_false_path` 就不会生效，P&R 仍然报 −111 ps。**

原因：`F:\al\scripts\DefaultFlow.tcl` 第 80 行用 `[info exists sp]` 作为
"是否重读 ADC/SDC"的开关，而 **四个 lab 的 `settings.cfg` 原厂模板都没有 `set sp`**。
后果：约束只在综合第一段读一次，**P&R 阶段对 `.sdc` / `pin.adc` 的修改一律不生效**。

**操作**：综合跑完之后，TD 会生成/刷新 `settings.cfg`，**只改 phy_1 那一份**，
在 `set start_step` 那一行**上面**插入一行 `set sp 1`：

| 文件 | 插入内容 | 说明 |
|---|---|---|
| `...\camera_to_dsi_display_Runs\phy_1\settings.cfg` | `set sp 1` | ✅ **要加** |
| `...\camera_to_dsi_display_Runs\syn_1\settings.cfg` | **不要加** | ❌ 加了会报 `USR-8128 CRITICAL-WARNING: Please import a work model first.` 并立即失败 |

改完的样子（`phy_1/settings.cfg` 示例）：
```tcl
set run_type phy
set speed 3
set sp 1                     <-- 新增这一行
set start_step opt_place
set top_model_name {design_top_wrapper}
```

> `phy_1/settings.cfg` 目前**不存在** —— 它是综合/P&R 首次运行时才生成的。
> 所以顺序是：**先跑综合 → 再补 `set sp 1` → 再跑 P&R**。
>
> 如需我代劳，告诉我一声即可（脚本化插入，幂等、纯 ASCII）。
> **注意**：任何一次 `reset_run` 都会重新生成 `settings.cfg`，把这一行冲掉，需重补。

---

## 6. 跑 P&R（Physical Design）

1. 选中 **phy_1**，点 **Run**（或 Run Implementation / Place & Route）。
2. **期望**：成功，并生成 bitstream。
3. **必查**（确认约束真的被读了）：
   ```
   <lab>\td_project\camera_to_dsi_display_Runs\phy_1\run.log
   ```
   应能搜到这两行：
   ```
   start command "read_adc ../../../user_source/constraints_source/pin.adc"
   start command "read_sdc ../../camera_to_dsi_display.sdc"
   ```
   **搜不到** ⇒ `set sp 1` 没生效，回到第 5 步。

---

## 7. 验收数字（跑通后逐项对照）

打开 `...\phy_1\route_flow.status` 与 `...\phy_1\camera_to_dsi_display_phy.area`：

| 指标 | **应为** | 说明 |
|---|---|---|
| **Setup WNS** | **+115 ps 左右，NUM_FEPS 0** | 若仍是 −111 ps / 2 FEPs ⇒ `set sp 1` 没生效 |
| **Hold WNS** | **+20 ps，NUM_FEPS 0** | |
| **全部 path group** | **0 违规** | |
| **slice** | **≈15,446（72.80%）** | 判据 `< 21216` |
| **LUT6** | ≈13,545（63.84%） | |
| **寄存器** | ≈13,637 | |
| **ERAM** | **40 / 108** | 判据 `< 108`，且**不应新增** |
| **DSP** | **9 / 40** | |
| **f7mux** | 32 | |

**若 slice 只有 ≈12,196、LUT6 只有 ≈9,844、DSP 只有 8** ⇒
**跑的是旧网表（lab1 直通），4 个新文件没进设计**，回到第 1、2、4 步。

**含新功能的旁证**：
- `camera_to_dsi_display_phy.area` 的层级报告里应出现
  `u_key_mode_ctrl`（≈73 gate / 86 DFF / 101 LUT）、
  `u_anlogic_logo_rom`（≈47 gate）、
  `u_edge_detect_96`（≈297 gate / 68 DFF / 118 LUT）。
  （`u_osd_char_lib` 不在报告里是**正常**的 —— 纯常量字库，被常量传播吸收进 `u_hdmi_mixer`。）
- 压缩版 bitstream 大小应约 **1,347,505 B**；
  若约 1,345,649 B ⇒ 那是 lab1 直通版的数字。

---

## 8. 烧写与上板

烧 `<lab>\td_project\camera_to_dsi_display_Runs\phy_1\camera_to_dsi_display.bit`。

**完整的上板步骤、期望现象、排障表**见：
`doc/analysis/上板测试-操作手册.md`

要点：
- 建议**先烧 `best_result/`（lab1 直通版）做 bring-up 对照**，确认板子/HDMI/摄像头这条链路是好的，
  再烧新版本验证新功能。
- 按键：**KEY1 = D5**（短按切边缘检测，长按调 AE）、**KEY2 = A9**（短按切 OSD，长按调 AE）。

---

## 9. 三个必须避开的坑（本次都实际踩过）

| # | 坑 | 现象 | 避开方法 |
|---|---|---|---|
| 1 | **GUI 的 `reset_run` 会回退编译列表** | 综合报 4 条 `HDL-8007 black box` | 改动编译列表后**重开工程**让 GUI 重载；不要在列表未确认时点 Reset Runs |
| 2 | **只重跑 P&R 等于白跑** | P&R 成功但资源还是旧数字（12,196 / 9,844 / 8） | P&R 从 `syn_1/..._gate.db` 导入网表；**改了编译列表必须重跑综合** |
| 3 | **`settings.cfg` 每次 `reset_run` 都会被重生成** | 刚加的 `set sp 1` 消失，时序又变成 −111 ps | 每次 Reset 后重补 `set sp 1`；用 `run.log` 里能否搜到 `read_sdc` 来验证 |
