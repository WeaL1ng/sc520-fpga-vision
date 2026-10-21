# 撕裂根因报告：awb 乘法器 TDM 化导致吞吐回归

> 日期：2026-09-20
> 触发：用户上板反馈「摄像头可用，屏幕只有一半会动，且撕裂」，且 **P1a 与 P1b 两个比特流症状相同**
> 结论：**根因是 P1a（AWB 重构）引入的吞吐回归，不是 P1b、不是时钟、不是复位、不是摄像头。**

---

## 0. 一句话结论

lab4 **原始**的 `awb` 用 **8 个并行乘法器**，吞吐 **1.34 拍/字**；
P1a 把它改成「**2 个乘法器 + 4 相 TDM**」，吞吐降到 **4.18 拍/字**，
而结构上限只有 **4.34 拍/字**（余量 3.7%）。
`awb` 内部的 512 深 FIFO 每行净积压约 **240 字**，两行就溢出；
该 FIFO 满时**静默丢弃写入**（IP 源码 `soft_fifo_al_f58e8b3e1f3d.v:77`
`wr_en_s = (!full_flag) & we`），丢字在屏幕上的表现正是**撕裂 / 只有一半画面在动**。

**处置：已把 `awb.v` 恢复为厂商原版（8 并行乘法器），实测 1.34 拍/字、零丢字。**

---

## 1. 证据链

### 1.1 机理（源码级，非推断）

| 事实 | 出处 |
|---|---|
| FIFO 满时写入被静默丢弃，无溢出标志 | `user_source/ip_source/w155_d512_fifo/soft_fifo_al_f58e8b3e1f3d.v:77` `assign wr_en_s = ((!full_flag) & we);` |
| FIFO 深度 512 | 同文件 `full_flag = (wr_addr_diff >= FULL_NUM)`，`FULL_NUM=512` |
| `awb` 每行输出是「**320 拍连续突发 + 51 拍空档**」 | `signal_delay.v:76-80`：`rd_valid` 在 `h_cnt==DELAY_CYCLE-3`(=51) 拉高，连发 `IMG_WIDTH/4`(=320) 拍后拉低 |
| TDM 读侧固定 **4 拍/字** | P1a 版 `awb.v`：`mul_ph` 0..3 四相 + `fifo_rd` 条件 |
| ISP 域时钟 = **59.995 MHz** | `_stage/lab4_p1b_release_20260920_171223/camera_to_dsi_display_pr.timing`：`clk0: 59.995 ... MIPI_RX_BYTE_CLK`（period 16.668 ns） |
| 吞吐预算 = **4.34 拍/字** | 59.995 MHz ÷ (55.296 Mpix/s ÷ 4 pix/字) = 59.995e6 / 13.824e6 = **4.34** |

**每行账**：突发窗口 320 拍内，读侧只能读 320/4 = 80 字 ⇒ 净积压 **240 字/行**。
512 深的 FIFO ⇒ **第 2 行即溢出**。实测「首次丢字在第 886 拍」≈ 2 行（371 拍/行），**完全吻合**。

### 1.2 仿真实测（三级对照）

测试台 `sim/p1b/tb_awb_rate3.v`，激励为**真实突发形态**（320 字连发 + 51 拍空档 × 60 行）。
用 `divider_beh.v`（50 拍延迟/1 结果每拍的行为模型，已与门级网表逐拍核对）替换
64k 行的 `divider_gate.v` 以把仿真时间从 >600 s 压到 ~5 s。

| DUT | cycles/word | 丢字 drop | FIFO 峰值 | 判定 |
|---|---|---|---|---|
| `awb_ref`（厂商原版，8 并行乘法器） | **1.34** | **0** | — (无 FIFO) | ✅ PASS |
| **恢复后的 lab4 `awb.v`** | **1.34** | **0** | — (无 FIFO) | ✅ **PASS** |
| P1a TDM 版 + D4 修复 | 4.18 | **13137** | 511/512 爆 | ❌ FAIL |
| P1a TDM 版（D4 未修） | **5.00** | **29636** | 511/512 爆 | ❌ FAIL |

复现命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File tools\run_d4_ab_launcher.ps1 -Which all
# 日志：_stage\d4_rate2\<ref|fixed|unfixed>\sim.log
# 结果：_stage\d4_rate2\吞吐对照结果.md
```

### 1.3 溯源：厂商原版 vs P1a 改造

| 文件 | 大小 | md5 | 架构 |
|---|---|---|---|
| lab1/lab2/lab3 的 `hdl_source/awb.v` | 13,082 B | `11D2396342D218AB2E60CC0F4AD9C1E4` | **8 并行乘法器 / 2 除法器 / 无 FIFO** |
| lab4 **被 P1a 覆盖后**的 `awb.v` | 15,167 B | `736ECC12DEB9F1F01B85C30E0ADB6DBC` | 2 乘法器 + 4 相 TDM / 有 FIFO |

lab1/2/3 三份 `awb.v` **md5 完全相同**，且 `divider_gate.v` 三份与 lab4 逐字节相同（`8FC2736192093D2E17F6831C1DFBD052`）
⇒ 基线可**直接、安全**地落回 lab4。

### 1.4 设计文档早就预警了（这是最值得记取的一条）

`doc/analysis/P1a-AWB重构设计.md` 的风险表：

> **R4 间隙吞吐**：若上游 ISP 在某段真的连续满速（行有效窗口内峰值 0.29~0.4 beat/clk），
> **4 拍/字的分时不够**（需 2.5 拍/字）⇒ **先用 2 个 DSP、2 拍/字** …
> **⇒ 推荐 2 DSP 方案（省 6 → 4 个 DSP 的保守版是 4 DSP / 2 拍）。**

**P1a 实际实现成了 4 拍/字（TDM=4），即违背了自家 R4 缓解措施。**
`doc/analysis/P1a修改核查与收益实测.md` §157 也已把 D4 列为「唯一需要持续关注的隐患」，
并写下「需上板观察有无撕裂」——本次上板把这个隐患坐实了。

**教训**：P1a 的验收只做了**资源差分**（DSP 8→2），**没有做吞吐验收**。
吞吐是这类"分时复用"改造的第一性约束，必须与资源同时验收。

---

## 2. 已执行的处置

1. **备份**当前 P1a 版本 → `_backup_awb_P1a_TDM_20260920/awb.v.P1a_TDM_superseded`
2. **恢复** lab4 `awb.v` 为厂商原版（`md5 11D23963…`，13,082 B）
3. **仿真验证**：`tb_awb_rate3` 对 `fixed` 分支（即 lab4 实际文件）实测 **1.34 拍/字、0 丢字** ✅
4. **并入 P1b** Logo→ERAM 改动（原目录此前没有）：`hdmi_mixer.v`(P1b) + `logo_rom_eram.v`；
   备份原 `hdmi_mixer.v` → `_backup_hdmi_mixer_pre_P1b_20260920/`
5. **登记源文件**：`.al`（IDE 工程）**与 `_Runs/*/camera_to_dsi_display.prj`（TD 实际读取的文件列表）**
   都把 `anlogic_logo_rom.v` 换成 `logo_rom_eram.v`

> ⚠ **重要发现（踩坑记录）**：TD 流程读的是 `_Runs/<run>/camera_to_dsi_display.prj`，
> **不是** `td_project/camera_to_dsi_display.al`。只改 `.al` 会导致
> `HDL-8007 ERROR: logo_rom_eram is a black box`，
> 且 `read_design` 阶段直接失败（但脚本退出码仍为 0，**必须查日志而不能只看退出码**）。

---

## 3. 恢复的代价与收益（门级综合实测）

P1a 的资源账（来自 `P1a修改核查与收益实测.md`）+ **本轮恢复后的门级实测**
（`syn_1/camera_to_dsi_display_gate.area`，opt_gate 后）：

| 资源 | 恢复后（8并行 + P1b） | P1a(TDM) | 恢复的净效果 |
|---|---|---|---|
| `u_awb` DSP | **8** | 2 | +6 |
| `u_awb` ALU/加法器 LUT | 2,292 | 2,293 | ≈0 |
| `u_awb` reg | **6,066** | 6,827 | **−761** ✅ |
| `u_awb` ERAM | **10** | 13 | **−3** ✅ |
| `u_hdmi_mixer` LUT | **280** | 2,572 | **−2,292**（P1b 收益）✅ |
| `u_logo_rom_eram` | 7 slice / 7 ERAM | — | P1b 新增 |
| **全设计 slice** | **13,347 / 21,216 = 62.91%** | 16,466 = 77.61% | **−3,119（省 14.7 个点）** ✅ |
| 全设计 lut6 | 11,063 / 21,216 = 52.14% | 14,490 | **−3,427** ✅ |
| 全设计 slice reg | 13,718 / 42,432 = 32.33% | — | — |
| 全设计 ERAM | 48 / 108 = 44.44% | 43 | +5 |
| 全设计 DSP | **8 / 40 = 20.00%** | 3 / 40 = 7.50% | +5 |
| 全设计 dram lut | 552 | 96 | +456 |
| **Setup SWNS** | **+1.182 ns** | +0.010 ns | ✅ 大幅改善 |
| **Setup STNS** | **0.000 ns（零违规）** | 0 | ✅ |
| **Hold HWNS / HTNS** | +0.020 ns / 0.000 ns | +0.020 / 0 | ✅ |
| P&R 耗时 | 8.41 分钟 | 18 分 9 秒 | ✅ −9.5 分钟 |

> 上表「恢复后」一列取自 `phy_1/camera_to_dsi_display_phy.area` 与 `..._pr.timing`（2026-09-20 20:50）。
> `u_awb` 布线后：1,782 slice / 2,292 lut6 / 6,055 reg / 10 ERAM / **8 DSP**；
> `u_hdmi_mixer` 302 slice / 266 lut6；`u_logo_rom_eram` 11 slice / 7 ERAM。

**结论：恢复基线不但把吞吐余量从 1.03× 拿回到 3.2×，还净省 3,119 个 slice
（62.91% vs P1a 的 77.61%），代价只是 DSP 从 7.5% 升到 20%。**


原因有两层：
1. 8 个 `8×8` 乘法器映射到 **8 个 DSP**，反而比 TDM 版的「2 DSP + 分时状态机 + 155-bit FIFO
   + 相位寄存器堆」**更省逻辑**（TDM 版多出 761 reg、3 ERAM、以及 `u_awb` 之外的布线压力）；
2. P1b 把 Logo 从组合 ROM 改成 ERAM，收回约 2,292 LUT。

> 原 P1a 的"省 6 个 DSP"收益，在 DSP 仅用 7.5% 的器件上**并无实际价值**；
> 而它花掉的 21.9 个点 slice 却实打实地挤压了后续算法（P5/P6）的空间。
> **⇒ P1a（乘法器 TDM 化）应判定为负收益改造，已回退。**


---

## 4. 构建结果与上板指引

### 4.1 构建流水（全部成功，无错误）

| 阶段 | 耗时 | 产物 |
|---|---|---|
| `syn_rtl`（read_design → opt_rtl） | 2.36 分钟 | `camera_to_dsi_display_rtl.db` |
| `syn_gate`（opt_gate） | 1.76 分钟 | `camera_to_dsi_display_gate.db` |
| `phy`（opt_place → opt_route → bitgen） | 8.41 分钟 | `camera_to_dsi_display.bit` |

命令（分段后台跑，规避 600 s 工具上限）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\td_stage.ps1 -Stage syn_rtl
powershell -NoProfile -ExecutionPolicy Bypass -File tools\td_stage.ps1 -Stage syn_gate
powershell -NoProfile -ExecutionPolicy Bypass -File tools\td_stage.ps1 -Stage phy
```

### 4.2 时序（零违规）

`SWNS +1.182 ns`、`STNS 0.000 ns`、`HWNS +0.020 ns`、`HTNS 0.000 ns`
（对比 P1a 的 `SWNS +0.010 ns`，裕量提升 118 倍）

### 4.3 上板烧写

**比特流**：
```
rtl_vendor\anlogic_example\lab_ex4_all_features_SC500_720P\lab_ex4_all_features\
    td_project\camera_to_dsi_display_Runs\phy_1\camera_to_dsi_display.bit
    （1,789,539 B，2026-09-20 20:50:08）
```

**发布包**：`_stage\lab4_baseline_awb_release_20260920_205022\`
（含 `.bit`、压缩版 `.bit`、时序/面积报告、三个关键 RTL 源）

**验收要点**：
1. 撕裂 / 半屏不动应**完全消失**（这是本次修复的目标症状）
2. 画面颜色应与 lab1/lab2/lab3 一致（AWB 恢复为厂商原版算法）
3. OSD「安路」Logo 位置在左上角 (7,34)–(153,128)（P1b 已用过仿真验证）
4. 状态栏 / 模式数字仍应正常

### 4.4 ✅ 上板验证结果（2026-09-20）

> **用户上板复测确认：功能已恢复 —— 撕裂消失，画面正常。**

至此本根因判定**闭环**：

```
仿真（真实突发激励）  →  综合  →  P&R（零时序违规）  →  上板（撕裂消失）
   1.34 拍/字 / 0 丢字       ✅         SWNS +1.182ns              ✅
```

| 环节 | 结论 |
|---|---|
| 根因假设「AWB 吞吐不足 ⇒ FIFO 静默丢字 ⇒ 撕裂」 | ✅ 被上板证实 |
| 处置「恢复厂商原版 8 并行乘法器」 | ✅ 有效 |
| 副作用（面积 / 时序 / 颜色 / OSD） | ✅ 无（slice 反而降到 62.91%，时序裕量提升 118 倍） |

---

## 5. 待办

- [x] 重新综合 → P&R → bitgen
- [x] 用 `camera_to_dsi_display_phy.area` 填实资源对比表
- [x] **上板复测：功能已恢复，撕裂消失（2026-09-20）**
- [x] 更新 `P1a修改核查与收益实测.md`：文首已标注结论作废，改为「**负收益改造，已回退**」
- [ ] 更新 `赛题二-分阶段实施方案.md` 中 P1a 条目（尚待处理）
- [ ] `P1b完成报告.md` 补充说明：P1b 的 Logo 收益成立，但它**不是**撕裂原因（尚待处理）
- [ ] 下一阶段：`gray_binary_96` 等合规算法接入（赛题 2.3 要求算法 ≠ 参考例程 `lab_ex_2` 的边缘检测）

---

## 5.1 本次事故的可复用心得

1. **分时复用换面积的改造，吞吐必须与资源同时验收。** P1a 只做了资源差分，
   漏掉的吞吐验收最终由"上板撕裂"来补 —— 代价是一个完整的构建周期。
2. **吞吐验收的激励必须是真实突发形态。** `awb` 写侧是「320 拍连发 + 51 拍空档」，
   按均匀流灌数据会得出"平均达标"的**假结论**（第一版 `tb_awb_rate.v` 就是这样翻车的）。
   判据要用**最坏突发**，不是平均值。
3. **自己写的设计文档里的风险表要当真。** `P1a-AWB重构设计.md` 的 R4 已明确写出
   「4 拍/字不够、推荐 2 拍/字」，实现却没照做。**风险表不是免责声明，是待办清单。**
4. **TD 流程读 `_Runs/<run>/camera_to_dsi_display.prj`，不是 `td_project/*.al`。**
   只改 `.al` 会导致 `HDL-8007 ... black box`，且**失败时脚本退出码仍为 0**，必须查日志。
5. **门级除法器网表（`divider_gate.v`，64k 行）会让仿真超时。**
   用 `divider_beh.v`（已与门级逐拍核对的行为模型）替换后，仿真从 >600 s 降到 ~5 s。


---

## 6. 遗留的正确性注意点

厂商原版 `awb` 与 P1a 版有两处**语义差异**（恢复后回到原版行为）：

| 项 | 厂商原版 | P1a 版 | 影响 |
|---|---|---|---|
| `tuser`/`tlast` 对齐 | `O_tuser = I_tuser`（**透传，不对齐**）、`O_tlast = (valid_d1==0)&&(valid_d2==1)` | 打包进 155-bit FIFO 与输出字对齐 | 下游 `data_96bit_to_128bit` 只用 tuser 复位 `S_cnt`，`edge_detect_96` 只用它清窗口 ⇒ **两者都能工作**（P1a 报告 §3 已确认） |
| 除法器 `start` | 每 valid 拍重触发 | 同上 | 相同 |

原版 `awb` 在 lab1/lab2/lab3 中已上板验证可用，故**恢复后不存在未验证的新语义**。
