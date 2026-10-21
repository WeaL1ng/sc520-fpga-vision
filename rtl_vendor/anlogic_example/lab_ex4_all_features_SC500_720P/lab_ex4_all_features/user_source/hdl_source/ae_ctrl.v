// ============================================================================
//  ae_ctrl.v  ---  AE 闭环控制器（P6 / 基础要求④"光线剧烈变化时工作正常" + 进阶⑤）
//
//  时钟域：**D1 = S_24m_clk（实测 23.81 MHz）**，与 `ae_set.v` / I2C 同域。
//          亮度统计在 ISP 域（60 MHz）算好后**每帧跨一个标量组**过来。
//
//  ---------------------------------------------------------------------------
//  ★ 为什么控制器不在 ISP 域做
//  ---------------------------------------------------------------------------
//  AE 的执行机构是 I2C（写 SC500 的 0x3e00~0x3e02 / 0x3e08~0x3e09），
//  而 I2C 已经是 24 MHz 域。把控制器放同域可以省掉一次跨域，且 24 MHz 有
//  **一整帧（16.7 ms）** 的时间预算 —— 这点逻辑量在这里几乎不占时序。
//
//  ---------------------------------------------------------------------------
//  ★★ 控制律：比例 + 死区 + 自适应步长 + 方向反转阻尼（**刻意不做积分项**）
//  ---------------------------------------------------------------------------
//   偏差分区（全部用**常量比较**，不做除法/乘法）：
//       far  : sum > 2·MID    或 sum < MID/2      ⇒ 偏差 > 100%
//       mid  : sum > 1.5·MID  或 sum < (2/3)·MID  ⇒ 偏差 > 50%
//       near : sum > 1.3·MID  或 sum < (10/13)·MID⇒ 偏差 > 30%
//   死区：|sum − MID| ≤ MID×DZ_PCT% ⇒ **不动**（防振荡）
//
//   ★ 为什么不做积分项：本回路的执行机构（曝光/增益）本身带"记忆"，
//     被控量（帧亮度）对执行量没有稳态误差 —— 比例 + 死区就够了。
//     **没有积分器 ⇒ 没有积分饱和 ⇒ 场景突变时不需要"重置积分器"**。
//     （原方案里的"帧内容突变 >50% 重置积分器"因此**删掉**，改为
//       "偏差分区每帧重算" —— 效果等价而实现更简单。）
//
//   ★ 方向反转阻尼：本次要动的方向与上次相反时，步长右移 1 位（减半）。
//     这是最基本的抗"过冲—回摆"手段，比拉长节流更有效（加大死区/加长节流
//     是最后手段，不是第一手段）。
//
//  ---------------------------------------------------------------------------
//  ★ 执行机构的优先级（决定"先动谁"，有明确工程理由）
//  ---------------------------------------------------------------------------
//   变亮：**先加曝光，再加模拟增益** —— 加曝光是"多收光"，信号与噪声同比例
//         上升，SNR 不变；加增益是"把已有信号放大"，噪声一起放大，SNR 变差。
//   变暗：**先减模拟增益，再减曝光** —— 对称的理由（先把噪声源压掉）。
//   高光保护：`clip` 超限时**无条件变暗**（不看 sum）——
//         否则"画面中心很暗 + 窗户过曝"这类场景会被 sum 均值骗过去，
//         继续加曝光把高光烧成一片白。这是 AE 最常见的翻车点。
//
//  ---------------------------------------------------------------------------
//  ★★ 已知的硬件天花板（**必须如实说明，不能假装能解决**）
//  ---------------------------------------------------------------------------
//   上板实测（用户 2026-09-21 反馈）：**默认画面偏暗**，而此时
//       AE = 1990（`ae_set.v` 的默认值**就是上限**，≈995 行 @ VTS=1000）
//       AG = 80   → `SC500GainTbl` 索引 64 → `0x0F20` ≈ **16 倍模拟增益**
//   ⇒ "出厂默认"已经贴着两个执行机构的上限跑，**向上几乎没有余量**。
//   本模块能做的是把仅有的余量用满：
//       AE 上限 1990（法律上限，不能再高，否则超过帧周期）
//       AG 上限由参数 `AG_MAX` 决定：
//          89  = 厂家表原样（索引 73 = 0x0F29 ≈ 20.5 倍）—— **已验证可用**
//          111 = 把厂家表补全到 0x0F3F（索引 95 ≈ 31.5 倍）—— **+97%**
//                依据：表里前两个十倍段都写满了 0x20~0x3F 共 32 项，
//                第三个十倍段只写到 0x0F29（10 项）就断了 ⇒ **是漏写，不是上限**。
//                ⚠ 这是**推理**而不是实测，故默认值保守取 89，
//                  把 111 留给上板 A/B 验证（见 P6 报告 §L4 风险表）。
//   若两个上限都打满仍偏暗，唯一出路是**数字增益**（ISP 域乘一个可变系数）
//   —— 那需要真正的可变乘法器（铁律三只禁止**常量**乘法用 DSP），
//   本阶段**不做**，如实记录为 P6b。
//
//  ---------------------------------------------------------------------------
//  ★ 跨域：准静态多比特 + 翻转标志（与 P5 同一套，已在板上验证）
//  ---------------------------------------------------------------------------
//   写侧（luma_stats）：帧末锁存 {sum, clip, avg} 并翻转 `O_tog`。
//   读侧（本模块）：2-FF 同步 tog → 边沿检测 → **整组捕获**。
//   为什么安全：数据一帧只变一次（≈16.7 ms），同步器 2 拍 ≈84 ns 后才看到
//   翻转，而数据还要再静止 ≈16.6 ms ⇒ 捕获瞬间绝不撞上跳变。
//   ⚠ 前提：若这些量将来变成"每拍都变"，必须改乒乓（参考 frame_latency.v）。
// ============================================================================
`timescale 1ns/1ps

module ae_ctrl #(
    // ---- 图像几何（必须与 luma_stats / target_detect_96 一致）----
    parameter integer IMG_WIDTH       = 1280,
    parameter integer IMG_HEIGHT      = 720,

    // ---- 目标亮度与死区 ----
    parameter [7:0]   TARGET_LUMA     = 8'd112,   // 目标平均亮度（0..255）
    parameter integer DZ_PCT          = 3,        // 死区 ±3%

    // ---- 执行机构范围 ----
    parameter [15:0]  AE_MIN          = 16'd2,
    parameter [15:0]  AE_MAX          = 16'd1990,
    parameter [15:0]  AG_MIN          = 16'd16,
    parameter [15:0]  AG_MAX          = 16'd89,   // 89=厂家表原样(已验证) / 111=补全表(+97%)
    parameter [15:0]  AG_INIT         = 16'd80,   // 出厂默认，装上 P6 后画面不变

    // ---- 高光保护：clip 像素数超过全画面 CLIP_PCT% 就无条件变暗 ----
    parameter integer CLIP_PCT        = 2,

    // ---- 平均亮度：avg = ((ΣY >> AVG_SHIFT) × AVG_RECIP) >> AVG_RSHIFT ----
    //   ★ 为什么放在**本模块（24 MHz 域）**而不是 `luma_stats`（60 MHz 域）：
    //     这一项要在 ΣY 之后做 6 项 33 位移位加法。放在 ISP 域时，布线实测
    //     它成了**该域最差路径的尾巴**（16.307 ns > 16.668 ns 周期，
    //     本域 Fmax 77.954 → **60.361 MHz，余量只剩 +0.6%**）。
    //     搬到 24 MHz 域（周期 42 ns）后完全无关紧要。
    //   ⚠ 它**只用于 OSD 显示**，与死区判决无关（判决用 ΣY 直接比常量阈值），
    //     所以放在哪个域对功能没有任何影响 —— 但**对时序影响巨大**。
    //   921600 = 900 × 2^10，round(2^24/900) = 18642（穷举验证误差 0 LSB）
    parameter integer AVG_SHIFT       = 10,
    parameter integer AVG_RECIP       = 18642,
    parameter integer AVG_RSHIFT      = 24,

    // ---- 节流：每 THROTTLE 个"新统计帧"才允许动一次 ----
    //   I2C 一次要写 5 个寄存器（0x3e00~02 + 0x3e08~09），100 kHz 下约 2 ms
    parameter integer THROTTLE        = 2
)(
    input  wire        I_clk,        // 23.81 MHz（D1 域）
    input  wire        I_rst_n,

    // ---- 跨域输入（来自 luma_stats，ISP 域 60 MHz）----
    input  wire [31:0] I_stats_sum,
    input  wire [19:0] I_stats_clip,
    input  wire        I_stats_tog,

    // ---- 同域反馈：ae_set 当前**已生效**的值（切换自动/手动时要无缝衔接）----
    input  wire [15:0] I_ae_cur,
    input  wire [15:0] I_ag_cur,

    // ---- 自动/手动（1=自动；短按 KEY2 切换，见 key_mode_ctrl.v）----
    input  wire        I_auto_en,

    // ---- 目标值（送给 ae_set；自动模式下由它直接采用）----
    output reg  [15:0] O_ae,
    output reg  [15:0] O_ag,

    // ---- 诊断（给 OSD / 仿真）----
    output reg  [31:0] O_avg_sum,    // 本帧捕获的 ΣY（跨域后）
    output reg  [7:0]  O_avg_luma,   // 本帧平均亮度（跨域后）
    output reg  [19:0] O_clip_luma,  // 本帧过曝像素数
    output reg  [1:0]  O_dir,        // **上一次实际动作**的方向（0=还没动过 1=变亮 2=变暗 3=高光保护降）
                                     //   ★ 只在实际动作时更新，**不做"无动作就清零"** ——
                                     //     否则 OSD/调试抓到的多半是 0：节流决定每 2 帧才动一次，
                                     //     中间那一帧会把方向冲掉（L1 测试就是这么抓出来的）。
    output reg  [15:0] O_upd_cnt,    // 累计下发次数（诊断"到底动没动"）
    // ★ 饱和指示（给 OSD）：bit1 = 有执行机构顶在**上限**（想变亮但没余量），
    //                        bit0 = 有执行机构抵在**下限**（想变暗但没余量）
    //   为什么必须把它显示出来：2026-09-23 上板出现"增益顶在 89、曝光顶在 1990、
    //   而平均亮度还远高于目标"的现象 —— 只看 AE/AG 数值要靠心算才知道"到顶了"，
    //   有了这一位，一眼就能区分"闭环在正常调节"和"闭环卡在极限"。
    output reg  [1:0]  O_sat,
    output reg         O_new_frame   // 收到一帧新统计（同域单拍）
);

    // ================================================================
    // 0. 常量阈值（elaboration 时算好 ⇒ 回路上只有比较器）
    // ================================================================
    localparam integer PIX_FRAME = IMG_WIDTH * IMG_HEIGHT;          // 921600
    localparam integer SUM_MID   = TARGET_LUMA * PIX_FRAME;         // 103,219,200 (@112)
    localparam integer SUM_HI    = SUM_MID + (SUM_MID * DZ_PCT) / 100;
    localparam integer SUM_LO    = SUM_MID - (SUM_MID * DZ_PCT) / 100;

    localparam integer SUM_FAR_HI = SUM_MID * 2;                    // 偏差 > +100%
    localparam integer SUM_FAR_LO = SUM_MID / 2;                    // 比一半还暗 ⇒ >100% 偏暗
    localparam integer SUM_MID_HI = (SUM_MID * 3) / 2;              // 偏差 > +50%
    localparam integer SUM_MID_LO = (SUM_MID * 2) / 3;              // 偏差 > −33%
    localparam integer SUM_NR_HI  = (SUM_MID * 13) / 10;            // 偏差 > +30%
    localparam integer SUM_NR_LO  = (SUM_MID * 10) / 13;            // 偏差 > −23%
    localparam integer CLIP_LIMIT = (PIX_FRAME / 100) * CLIP_PCT;   // 过曝像素数上限

    // ================================================================
    // 1. 跨域接收：2-FF 同步 + 边沿检测 + 整组捕获
    // ================================================================
    reg        S_tog_s1, S_tog_s2, S_tog_s3;
    reg [31:0] S_sum_q;
    reg [19:0] S_clip_q;
    reg        S_sum_valid;                        // 收到第一帧统计前置 0（禁止乱动机构）
    //  ★★ 新统计"待决策"标志（L1 测试抓出来的真 bug 的修复，见文件尾"臭虫记录"）
    //     问题：捕获（S_sum_q <= I_stats_sum）与节流决策写在**同一个 always 块、
    //     同一个时钟沿**里 ⇒ 决策那一拍 `S_sum_q` 还是**上一帧的旧值**，
    //     于是每次动作都比数据**晚一帧**。单看闭环收敛"能收敛"是发现不了的，
    //     是 tb_ae_ctrl 组 1 的逐条断言把它钉出来的。
    //     修法：捕获时置位 `S_pending`，**下一拍**才用刚捕获的数据做决策。
    reg        S_pending;

    wire       w_tog_edge = S_tog_s2 ^ S_tog_s3;   // 同步后的翻转沿

    // ================================================================
    // 1b. 平均亮度（只给 OSD 显示；本域 24 MHz 有 42 ns 预算，够这笔加法树）
    //     18642 = 16384+2048+128+64+16+2（移位加法，无 `*` ⇒ 不吃 DSP）
    //     输入用**已寄存**的 S_sum_q（帧内完全静止）⇒ 路径起点是寄存器
    // ================================================================
    wire [17:0] w_s10    = S_sum_q[31:AVG_SHIFT];       // 上限 229500（18 位）
    wire [32:0] w_s10_e  = {15'd0, w_s10};
    wire [32:0] w_avg_acc = (w_s10_e << 14) + (w_s10_e << 11) + (w_s10_e << 7)
                          + (w_s10_e << 6)  + (w_s10_e << 4)  + (w_s10_e << 1);
    wire [7:0]  w_avg     = w_avg_acc[AVG_RSHIFT +: 8];

    // ================================================================
    // 2. 偏差分区（纯常量比较，无除法）
    // ================================================================
    wire w_too_bright = (S_sum_q > SUM_HI);
    wire w_too_dark   = (S_sum_q < SUM_LO);
    wire w_far        = (S_sum_q > SUM_FAR_HI) || (S_sum_q < SUM_FAR_LO);
    wire w_mid        = (S_sum_q > SUM_MID_HI) || (S_sum_q < SUM_MID_LO);
    wire w_near       = (S_sum_q > SUM_NR_HI)  || (S_sum_q < SUM_NR_LO);
    wire w_clip_over  = (S_clip_q > CLIP_LIMIT);

    // 本帧想往哪走（死区内两个都 false ⇒ 不动）
    wire w_will_brighten = w_too_dark && !w_clip_over;
    wire w_will_darken   = w_too_bright || w_clip_over;

    // 步长（自适应）：far > mid > near > 死区边缘
    wire [15:0] w_step_ae = w_far ? 16'd256 : (w_mid ? 16'd64 : (w_near ? 16'd8 : 16'd2));
    wire [15:0] w_step_ag = w_far ? 16'd8   : (w_mid ? 16'd2  : 16'd1);

    // ================================================================
    // 3. 执行机构可达性 + 目标推进
    // ================================================================
    reg [15:0] S_ae_t;      // 自动目标 AE
    reg [15:0] S_ag_t;      // 自动目标 AG
    reg [1:0]  S_dir;       // 上次实际动作方向
    reg [7:0]  S_thr;       // 节流计数

    wire w_ae_can_up = (S_ae_t < AE_MAX);
    wire w_ae_can_dn = (S_ae_t > AE_MIN);
    wire w_ag_can_up = (S_ag_t < AG_MAX);
    wire w_ag_can_dn = (S_ag_t > AG_MIN);

    // ae_set 已把上一次目标写进传感器（否则不下发新目标，防止命令堆积）
    wire w_committed = (I_ae_cur == O_ae) && (I_ag_cur == O_ag);

    // 方向反转 ⇒ 步长减半（抗过冲回摆）
    wire w_reverse    = (w_will_brighten && (S_dir == 2'd2)) ||
                        (w_will_darken   && (S_dir == 2'd1));
    wire [15:0] w_st_ae = w_reverse ? {1'b0, w_step_ae[15:1]} : w_step_ae;
    wire [15:0] w_st_ag = w_reverse ? {1'b0, w_step_ag[15:1]} : w_step_ag;

    // ★★ 饱和加/减（2026-09-23 修的真 bug，**上板照片定位**）
    // ----------------------------------------------------------------------------
    //  原写法 `S_ae_t + w_st_ae` / `S_ag_t - w_st_ag` **只判"能不能动"，不做钳位**：
    //    · 往上：S_ag_t=88（< AG_MAX=89 ⇒ "能动"）而步长=8 ⇒ 目标 **96 > AG_MAX**
    //            S_ae_t=1980 而步长=256 ⇒ 目标 **2236 > AE_MAX=1990**（非法曝光！）
    //    · 往下：S_ae_t=200 而步长=256 ⇒ `200-256` 在 16 位无符号下**下溢成 65480**
    //            ⇒ 把 65480 当目标写出去，而且
    //            `w_committed = (I_ae_cur == O_ae)` **再也无法成立** ⇒ 闭环永久冻结。
    //
    //  上板线索（用户照片，2026-09-23）：增益 `G 59`(=89, 顶) 、曝光 `07C6`(=1990, 顶)、
    //  而平均亮度 `L 93`(=147) **远高于目标 112** —— 正是"想往下调却卡住"的样子。
    //
    //  ⇒ 一律改成**饱和运算**，并输出 `O_sat` 给 OSD：
    //     首行第 2 槽显示 `+`（有执行机构顶在上限）或 `-`（抵在下限）。
    //     这一位下次上板一眼就能确认"是不是又一次卡在极限"。
    // ----------------------------------------------------------------------------
    function [15:0] sat_add;
        input [15:0] a, b, hi;
        begin
            if (a >= hi)          sat_add = hi;
            else if ((hi - a) < b) sat_add = hi;   // hi-a 不会下溢（a<hi）
            else                   sat_add = a + b;
        end
    endfunction

    function [15:0] sat_sub;
        input [15:0] a, b, lo;
        begin
            if (a <= lo)          sat_sub = lo;
            else if ((a - lo) < b) sat_sub = lo;   // a-lo 不会下溢（a>lo）
            else                   sat_sub = a - b;
        end
    endfunction

    // 变亮：先 AE（到顶才动 AG）
    wire [15:0] w_ae_up = w_ae_can_up ? sat_add(S_ae_t, w_st_ae, AE_MAX) : S_ae_t;
    wire [15:0] w_ag_up = (w_ae_can_up || !w_ag_can_up) ? S_ag_t
                                                       : sat_add(S_ag_t, w_st_ag, AG_MAX);
    // 变暗：先 AG（到下限才动 AE）
    wire [15:0] w_ag_dn = w_ag_can_dn ? sat_sub(S_ag_t, w_st_ag, AG_MIN) : S_ag_t;
    wire [15:0] w_ae_dn = (w_ag_can_dn || !w_ae_can_dn) ? S_ae_t
                                                       : sat_sub(S_ae_t, w_st_ae, AE_MIN);

    wire [15:0] w_ae_next = w_will_brighten ? w_ae_up : (w_will_darken ? w_ae_dn : S_ae_t);
    wire [15:0] w_ag_next = w_will_brighten ? w_ag_up : (w_will_darken ? w_ag_dn : S_ag_t);

    wire [1:0]  w_dir_next = w_clip_over    ? 2'd3            // 高光保护降
                           : (w_will_brighten ? 2'd1
                           : (w_will_darken   ? 2'd2 : 2'd0));

    // 只有"真能改变"时才允许消耗一次节流额度（否则 AE/AG 都到顶时会白等）
    wire w_can_move = (w_ae_next != S_ae_t) || (w_ag_next != S_ag_t);

    // ================================================================
    // 4. 时序
    // ================================================================
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_tog_s1 <= 1'b0; S_tog_s2 <= 1'b0; S_tog_s3 <= 1'b0;
            S_sum_q  <= 32'd0;
            S_clip_q <= 20'd0;
            S_sum_valid <= 1'b0;
            S_pending   <= 1'b0;
            S_ae_t   <= AE_MAX;      // ⚠ 初值 = 出厂默认（1990）⇒ 装上 P6 后画面不变
            S_ag_t   <= AG_INIT;     // ⚠ 同上（出厂默认 80）
            S_dir    <= 2'd0;
            S_thr    <= 8'd0;
            O_ae     <= AE_MAX;
            O_ag     <= AG_INIT;
            O_avg_sum   <= 32'd0;
            O_avg_luma  <= 8'd0;
            O_clip_luma <= 20'd0;
            O_dir       <= 2'd0;
            O_upd_cnt   <= 16'd0;
            O_sat       <= 2'd0;
            O_new_frame <= 1'b0;
        end else begin
            // ---------------- 跨域同步与捕获（永远做，与 auto/manual 无关）----------------
            S_tog_s1 <= I_stats_tog;      // ① 2-FF 同步
            S_tog_s2 <= S_tog_s1;
            S_tog_s3 <= S_tog_s2;         // ② 再打一拍做边沿检测
            O_new_frame <= 1'b0;
            S_pending   <= 1'b0;

            if (w_tog_edge) begin
                // ★ 整组捕获：此刻数据已静止 ≈16.6 ms，绝不会采到跳变中的值
                S_sum_q     <= I_stats_sum;
                S_clip_q    <= I_stats_clip;
                O_avg_sum   <= I_stats_sum;
                O_avg_luma  <= w_avg;            // ★ 本域算（见 §1b 的时序理由）
                                                 //   ⚠ 用的是**上一帧**已寄存的 S_sum_q
                                                 //     ⇒ 显示的均值比 ΣY 晚 1 帧（16.7 ms）。
                                                 //     刻意如此：让路径起点是寄存器，
                                                 //     而不是跨域输入引脚（TD 无法对
                                                 //     跨域引脚做有意义的时序约束）。
                O_clip_luma <= I_stats_clip;
                // 第一帧（S_sum_valid 还是 0）可能是"复位后的半帧"，**不决策**；
                // 从第二帧起，捕获完在下一拍用**刚捕获的数据**决策。
                S_pending   <= S_sum_valid;
                S_sum_valid <= 1'b1;
                O_new_frame <= 1'b1;
            end

            // ---------------- 自动 / 手动 ----------------
            if (!I_auto_en) begin
                // 手动：输出**跟随已生效值**，保证切回自动时无缝衔接
                //      （手动按键由 ae_set.v 自己维护，本模块不参与）
                O_ae   <= I_ae_cur;
                O_ag   <= I_ag_cur;
                S_ae_t <= I_ae_cur;
                S_ag_t <= I_ag_cur;
                S_thr  <= 8'd0;
                S_dir  <= 2'd0;
                O_dir  <= 2'd0;
            end else begin
                O_ae <= S_ae_t;
                O_ag <= S_ag_t;
                // 饱和指示：目标已经贴在钳位边界上（无论当拍有没有动作）
                O_sat <= { (S_ae_t >= AE_MAX) || (S_ag_t >= AG_MAX),
                           (S_ae_t <= AE_MIN) || (S_ag_t <= AG_MIN) };

                // ★ 用"上一拍刚捕获的"统计量决策（S_sum_q / S_clip_q 已是新值）
                if (S_pending) begin
                    // ---- 节流：攒够 THROTTLE 帧才允许动一次 ----
                    if (S_thr + 8'd1 >= THROTTLE) begin
                        S_thr <= 8'd0;
                        if (w_can_move && w_committed) begin
                            S_ae_t    <= w_ae_next;
                            S_ag_t    <= w_ag_next;
                            S_dir     <= w_dir_next;
                            O_upd_cnt <= O_upd_cnt + 16'd1;
                            O_dir     <= w_dir_next;      // 只在真动作时更新（粘住）
                        end
                        // ⚠ 这里**刻意不清 O_dir**：清了的话 OSD 上看到的
                        //   "上次动作方向"会在两帧之间被打回 0，等于没显示。
                    end else begin
                        S_thr <= S_thr + 8'd1;
                    end
                end
            end
        end
    end

endmodule
