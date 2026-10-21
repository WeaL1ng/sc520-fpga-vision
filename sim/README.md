# sim/ — ModelSim 仿真环境

> 建立于 2026-09-18。**2026-09-19 重大更新：已换成免费版 ModelSim，仿真可以跑了。**

---

## 0. 🔴 环境变更（2026-09-19）—— **仿真已可用，不再需要许可证**

| | 之前（09-18） | **现在（09-19）** |
|---|---|---|
| 仿真器 | ModelSim **SE-64 10.1c**，`F:\model` | **ModelSim ALTERA STARTER EDITION 10.3c**，`F:\modelsim\modelsim_ase\win32aloem` |
| 许可证 | ❌ **需要，但机器上没有任何 Mentor 许可证** | ✅ **免费版，不需要许可证** |
| `vsim` | ❌ exit 4 `Unable to checkout a license` | ✅ **实测可跑仿真** |
| `vopt` | ✅ 可用（无许可证） | ❌ **ASE 里没有 vopt.exe**（不影响仿真） |
| `F:\model` | 存在 | **已不存在**（SE 已卸载） |

**⇒ 功能仿真现在可以做。** 实测证据：

```
Model Technology ModelSim ALTERA STARTER EDITION vsim 10.3c Simulator 2014.09
$ vsim -c -quiet -lib work tb_key_mode_ctrl -do "run -all; quit -f"
  PASSED 15 checks, FAILED 0 checks
  *** ALL TESTS PASSED ***
  Errors: 0, Warnings: 0
```

> ⚠ **命令语法差异（已踩）**：`vsim` 用 **`-lib`** 指定库，**不是 `-work`**。
> 用错会报 `vish-3296 Unknown option '-work'`。
> `vlog` 则仍用 `-work`。

---

## 0.1 ✅ 当前可用的仿真能力

| 能力 | 工具 | 状态 |
|---|---|---|
| **功能仿真（跑激励、看波形、判定 PASS/FAIL）** | `vsim`（ASE） | ✅ **可用** |
| 编译 / 语法检查 | `vlog` / `vlib` / `vmap` | ✅ 可用 |
| **纯 RTL 模块的完整仿真** | `vsim` + 自建 TB | ✅ **可用**（已对 `key_mode_ctrl` 验证） |
| 依赖**安路加密 IP** 的模块 | — | ❌ 不可仿真（见 §5） |

### 🆕 已跑通的第一个 testbench

**`sim/tb/tb_key_mode_ctrl.v`** —— `key_mode_ctrl` 的功能自检，**15 项检查全过**：

| 用例 | 验证内容 | 结果 |
|---|---|---|
| T0 | 复位值 `O_mode=2'b00` / `O_btn_ae=2'b11` | ✅ |
| T1 | 短按 KEY0 → `mode[0]` 翻转，`mode[1]` 不变，AE 门控回 1 | ✅ |
| T2 | 再短按 KEY0 → 翻回 0 | ✅ |
| T3 | **长按 KEY0 → `mode[0]` 不翻转**，长按中 AE 门控=0，释放后回 1 | ✅ |
| T4 | 短按 KEY1 → `mode[1]` 翻转，`mode[0]` 不受影响 | ✅ |
| T5 | 长按 KEY1 → `mode[1]` 不翻转 | ✅ |
| T6 | **小于去抖时间的毛刺不触发切换** | ✅ |

**一键运行**：

```powershell
powershell -ExecutionPolicy Bypass -File .\sim\run_key_tb.ps1
```

### 为什么这个仿真"跑得快"

TB 用**缩短的时间参数**（CLK 50 kHz / 去抖 1 ms / 长按 2 ms），
使整份仿真在 **24.5 ms 仿真时间**内跑完，而真机是 500 ms 量级。
**逻辑与参数无关，缩短不影响结论。**

---

## 0.2 🆕 无许可证时代的替代手段（vopt 结构检查）—— 现在已被 `vsim` 取代

下面这套是 09-18 在"只有 SE 且无许可证"时的替代方案，**现在 `vsim` 可用了，它降级为辅助手段**：

| 脚本 | 作用 |
|---|---|
| `vopt_check.ps1` | 对 `awb` 做 vopt 结构检查 |
| `vopt_mod.ps1` | 对任意模块做 vopt 结构检查（端口自动提取） |
| `awb_ab_check.ps1` | A/B 结构对比 |

> ⚠ **注意**：这些脚本依赖 `vopt.exe`，而 **Altera Starter Edition 里没有 vopt**。
> 若要继续用，需要把脚本里的 `ModelRoot` 指回一个带 vopt 的 ModelSim（如 SE/PE）。
> **在 ASE 环境下，请优先直接用 `vsim` 做真正的功能仿真。**

---



## 1. 文件清单

| 文件 | 用途 |
|---|---|
| `add_modelsim.ps1` | **先跑这个**。体检：定位安装、版本、编译能力、许可证、库状态。`-Check` 只检查不改环境 |
| `build_libs_vlog.ps1` | 用 `vlog` 编译安路仿真库（`-Force` 重建）。**约 25 秒** |
| `tb_smoke.v` | 接入自检 testbench。例化安路原语 `PH1P_PHY_GSR`，验证库链接 + 时序推进 |
| `libs/anl_common/` | AL_* 通用单元（64 个） |
| `libs/anl_ph1p/` | PH1P 原语：ERAM / DSP / PLL / DPHY / DDRPHY …（1038 个） |
| `libs/work/` | 用户设计库（已含 `tb_smoke`） |
| `modelsim.ini` | 库映射（由 `build_libs_vlog.ps1` 生成） |

---

## 2. 为什么库要用 `vlog` 编，不能用 `vsim -c -do`

**`vsim` 的任何模式（包括 `-c` 纯命令行）都要签出许可证**，实测 exit 4。
而 `vlib` / `vlog` / `vmap` **不需要**。

所以安路官方常见的 `vsim -c -do "vlib ...; vlog ..."` 写法在本机会直接失败，
必须改成直接用 `vlog` 编译（`build_libs_vlog.ps1` 就是这么做的）。

---

## 3. 用法

### 3.1 体检（推荐先做）

```powershell
powershell -ExecutionPolicy Bypass -File .\sim\add_modelsim.ps1 -Check
```

### 3.2 编译安路仿真库（只需一次；重建加 `-Force`）

```powershell
powershell -ExecutionPolicy Bypass -File .\sim\build_libs_vlog.ps1
```

> ⚠ **本目录所有 `.ps1` 必须是「UTF-8 with BOM」。**
> 以 UTF-8 无 BOM 覆写会让 Windows PowerShell 5.1 按 GBK 解码 → 中文乱码 + 语法错误
> （已实测报 `Unexpected token` / `MissingCatchOrFinally`）。
> **每次用编辑器改完，务必确认 BOM 还在**（首 3 字节应为 `EF BB BF`）。
> 校验命令：
> ```powershell
> Get-ChildItem sim,tools -Filter *.ps1 -Recurse | ForEach-Object {
>   $b=[IO.File]::ReadAllBytes($_.FullName)
>   "{0,-24} {1}" -f $_.Name, $(if($b[0] -eq 0xEF){"BOM OK"}else{"!! 缺 BOM"})
> }
> ```

### 3.3 跑自检（需要许可证）

```powershell
cd sim
F:\model\win64\vlib work                       # 若 work 已存在可跳过
F:\model\win64\vlog -work work tb_smoke.v
F:\model\win64\vsim -c -L anl_common -L anl_ph1p -work work tb_smoke -do "run -all; quit -f"
```

预期末尾：

```
[SMOKE] 安路原语 PH1P_PHY_GSR 例化成功
[SMOKE] 20 拍后 cnt = 20 (期望 20)
[SMOKE] PASS
```

### 3.4 跑带图形界面

```powershell
F:\model\win64\vsim -voptargs="+acc" -L anl_common -L anl_ph1p -work work tb_smoke
# 然后在 Transcript 里：run -all
```

---

## 4. 为什么这个自检能区分两类问题

`tb_smoke.v` **不依赖任何加密 IP**（`hdmi_1_4b_transmitter_core_wrapper.enc.v`、
`alc_mc_top_all.enc.sv`、`byte_aligner.enc.v` 等一律不需要），
只需要 `anl_ph1p` 里的 `PH1P_PHY_GSR` 一个原语。

- 编译报错 → **环境/路径问题**
- 编译通过但 `vsim` 报 `Unable to checkout a license` → **纯许可证问题**

目前实测结果就是后者：**`vlog` exit 0、库链接成功，`vsim` exit 4 仅因许可证。**

---

## 5. ⚠ 仿真范围的重要限制：加密 IP 无法仿真

**这不是环境问题，是 ModelSim SE 的固有限制。** 下面这些文件是安路加密的
（`protected region`，实测编译时产生 454 条相关警告），普通 ModelSim SE 解不开：

| 加密文件 | 影响 |
|---|---|
| `hdmi_1_4b_transmitter_core_wrapper.enc.v`（329 KB） | **HDMI 输出链路无法仿真** |
| `alc_mc_top_all.enc.sv`（270 KB） | **DDR 控制器无法仿真** |
| `mipi_dphy_rx/*.enc.v`、`*.enc.sv` | **MIPI D-PHY 解包无法仿真** |

**⇒ 因此 `design_top_wrapper`（顶层）不能直接仿真。**
要仿真必须**切到边界以内**。

### 5.1 推荐的仿真切分

| 范围 | 是否可仿真 | 说明 |
|---|---|---|
| **ISP 链路**：`csi_unpacket_2lane` → `raw10_unpacket_2lane` → `uial2axis` → `demosaic` → `data128_96` → `awb` → `data_96bit_to_128bit` | ✅ **完全可以** | 全部是明文 Verilog，只依赖 `anl_ph1p` 的 ERAM/DSP 原语 |
| `video_in` / `video_out` | ✅ 可以 | 明文 + Soft_FIFO（明文） |
| `hdmi_mixer` / OSD（Logo、字库） | ✅ 可以 | 明文，只需喂 24 bit 像素流 |
| `hdmi_tx` | ❌ 不行 | 依赖加密的 HDMI 1.4b core |
| `ph1p35_324_ddr_wrapper` | ❌ 不行 | 依赖加密的算路控制器 |
| MIPI D-PHY | ❌ 不行 | 加密 |
| **整个 `design_top_wrapper`** | ❌ 不行 | 以上三者都在里面 |

### 5.2 这对当前工作（P1a AWB 重构）意味着什么

**刚好是好事**：`awb.v` 是明文，且它的验证本来就只需要 ISP 链路的输入输出，
不需要 DDR / HDMI / MIPI。所以：

> **ISP 切分仿真足以完成 P1a 的"改前/改后逐位一致"验收** ——
> 这正是 `doc/analysis/P1a-AWB重构设计.md` §7 步骤 ① 要求的那件事。

**⇒ 许可证一到手，第一件该跑的就是 `awb` 的 ISP 链路对照仿真。**

---

## 6. 如何解决 `vsim` 许可证（唯一阻塞项）

本机已装 ModelSim SE 10.1c，但没有任何许可证文件：

- 无 `LM_LICENSE_FILE` / `MGLS_LICENSE_FILE` 环境变量
- `F:\model\modelsim.ini` 里没有 license 配置行
- `F:\model\LICENSE` 是**版权声明文本**（27 KB），**不是**许可证
- 全盘搜索（`F:\`、`C:\`，深度 4）**未找到任何 `license.dat` / `*.lic` / `mgls*.dat`**

按推荐顺序的合法途径：

### ① 安路高校/杯赛配套授权【最推荐】
TD 安装自带 `F:\al\doc\SWUG\SWUG107_Design_Simulation_User_Guide.pdf`
（安路《设计仿真用户指南》SWUG107，TD6.0 V1.0），说明官方支持的仿真流程。
**安路通常会向参赛队/高校提供配套仿真授权**，索取渠道与索取 DS1300 资料同一个：

```
邮箱：web@anlogic.com
QQ 群：1050628457（赛题技术交流群）
```

> 注：该 PDF 的中文是 CID 字形编码，**普通文本提取工具解不出来**（只能读出英文）。

### ② 学校/实验室的 Mentor 授权服务器
若学校已购授权，只需指向许可证服务器：

```powershell
setx LM_LICENSE_FILE 27000@<license-server-host>
```

或在 `F:\model\modelsim.ini` 中加一节：

```ini
[mtiLicense]
LM_LICENSE_FILE = 27000@<license-server-host>
```

然后用 `C:\MentorGraphics\Install\bin\LMUTIL.EXE lmdiag` 诊断。

### ③ ModelSim - Intel FPGA Starter Edition（免费、无需许可证）
功能受限（不支持加密 IP —— 但**我们的加密 IP 本来也仿真不了**），
**足以仿真本节 §5.1 的 ISP 链路**。
代价：需另外下载安装；且它的原语库需另行编译（不能直接用本目录的 `anl_ph1p`）。

### ④ 关于 `F:\model\win64\MentorKG.exe`
该目录下存在 `MentorKG.exe`，这是**许可证生成器（keygen）**。

> **我不运行它，也不会生成许可证密钥。** 那属于绕过商业软件授权。
> 是否需要处理请你自行判断，并注意许可合规 —— 尤其是本项目是**要提交参赛的作品**，
> 使用未授权工具链存在合规风险。

---

## 7. 证据索引（本文件所有结论的实测来源）

| 结论 | 证据 |
|---|---|
| ModelSim SE-64 10.1c，`F:\model` | `vsim -version` → `ModelSim SE-64 vsim 10.1c Simulator 2012.07 Jul 28 2012` |
| `vlib`/`vlog` 不需要许可证 | 实测 `vlib exit=0`、`vlog exit=0`（编译 `anl_common` 13 文件 + `anl_ph1p` 78 文件） |
| `vsim` 任何模式都需要许可证 | `vsim -c -do ...` → `** Fatal: Invalid license environment`，exit 4 |
| 无任何许可证文件 | 环境变量扫描 + `modelsim.ini` 无 license 行 + 全盘深度 4 搜索 |
| 安路仿真模型是明文 Verilog | `F:\al\sim_release\ph1p\` 82 个文件；`ph1p_phy_gsr.v` 里 `module PH1P_PHY_GSR();` |
| 库规模 | `anl_common` 64 单元 / `anl_ph1p` 1038 单元（`protected region` 警告 454 条属正常） |
| `tb_smoke.v` 链接库成功 | `vlog -work libs\work -L anl_ph1p -L anl_common tb_smoke.v` → exit 0 |
| 加密 IP 清单 | `hdmi_1_4b_transmitter_core_wrapper.enc.v`、`alc_mc_top_all.enc.sv`、`mipi_dphy_rx/*.enc.*` |
| PowerShell 脚本必须带 BOM | 无 BOM 时实测报 `MissingCatchOrFinally` / `Unexpected token`；补 BOM 后正常 |
