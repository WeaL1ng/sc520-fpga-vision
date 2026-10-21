// ============================================================================
//  tb_ae_ctrl.v  ---  P6 AE 闭环控制器验证（L1）
//
//  分两组：
//
//  【组 1】开环决策断言 —— 把控制律的每一条单独钉死
//     T1  死区           sum 在 ±3% 内（含边界内 +2%）⇒ **不动**（防振荡）
//     T2  偏暗 + AE 到顶                     ⇒ **加 AG**（而不是死等 AE）
//     T3  偏亮（mid 档）                     ⇒ 变暗
//     T4  ★ 高光保护     均值偏暗 **但** 过曝像素超限 ⇒ **必须变暗**（不看 sum）
//         —— AE 最容易翻车的一条："均值偏暗 + 窗口过曝"会被 sum 骗过去，
//            结果为了提亮把窗户烧成一片白。
//     T5  手动模式       auto_en=0           ⇒ 只跟随已生效值，不下发
//     T5b 切回自动                            ⇒ 从**已生效值**无缝衔接
//     T10 曝光优先       AE 未到顶 + 偏暗      ⇒ **只加 AE，AG 不动**
//     T6  节流           第 1 个新统计帧不动、第 2 个才动（THROTTLE=2）
//     T9  方向反转阻尼   同方向时步长 8、反向时步长 **4**（减半）
//
//  【组 2】闭环收敛 + 抗振荡（★ 本 TB 最有价值的部分）
//     用一个**独立的传感器模型**把回路闭上：亮度 = f(曝光, 模拟增益)，
//     增益表按 `SC500GainTbl` 的编码逐位复刻（含**粗增益分段跳变**），
//     并且**带 1 帧响应延迟**（真实传感器不是当拍就变）。
//     两个 DUT 实例，只有 `AG_MAX` 不同：
//        dut_a : AG_MAX =  89（厂家表原样，索引 73 ≈ 20.5 倍）—— **已实测可用**
//        dut_b : AG_MAX = 111（补全表，  索引 95 ≈ 31.5 倍）—— 待上板验证
//
//  ⚠ 场景常数 `SCENE_LUMA_AT_DEFAULT = 60` 是**假设**，不是实测：
//     来源是用户 2026-09-21 的反馈"默认画面偏暗"。真正把默认亮度测出来要靠
//     上板的 OSD 诊断行（`L 6E` 那种读数）。本 TB 的结论因此是**条件式**：
//     "若默认平均亮度约 60，则 ……"。把假设写在代码里，比含糊其辞强。
//
//  ⚠ 期望值为什么必须"先算过再写"：`T3 减 8` 这种直觉写法是**错的** ——
//     sum=200×PIX 落在 mid 档（不是 far），步长是 2；加上方向反转阻尼再减半
//     ⇒ 实际可能是 1。**断言必须能从控制律一步步推出来**，否则测试本身在撒谎。
// ============================================================================
`timescale 1ns/1ps

module tb_ae_ctrl;

    localparam integer IMG_W = 1280, IMG_H = 720;
    localparam integer PIX   = IMG_W * IMG_H;       // 921600
    localparam integer TARGET_LUMA = 112;
    localparam integer DZ_PCT = 3;
    localparam integer SUM_MID = TARGET_LUMA * PIX;                        // 103,219,200
    localparam integer SUM_HI  = SUM_MID + (SUM_MID * DZ_PCT) / 100;
    localparam integer SUM_LO  = SUM_MID - (SUM_MID * DZ_PCT) / 100;
    localparam integer AE_MAX  = 1990;
    localparam integer AE_MIN  = 2;
    localparam integer AG_MIN  = 16;
    localparam integer AG_MAX_A = 89;
    localparam integer AG_MAX_B = 111;

    localparam integer SCENE_LUMA_AT_DEFAULT = 60;   // 假设：默认 AE/AG 下平均亮度

    reg clk = 0, rst_n = 0;
    always #1 clk = ~clk;

    integer err_cnt = 0;

    // ---- 辅助函数必须先声明（Verilog 不允许"先用后声明"的函数）----
    function integer abs_i;
        input integer v;
        begin
            abs_i = (v < 0) ? -v : v;
        end
    endfunction

    // ========================================================================
    //  DUT A / DUT B（唯一差别是 AG_MAX）
    // ========================================================================
    reg  [31:0] a_sum = 0;  reg [19:0] a_clip = 0;  reg a_tog = 0;
    reg  [31:0] b_sum = 0;  reg [19:0] b_clip = 0;  reg b_tog = 0;
    reg  [15:0] a_ae_cur = AE_MAX, a_ag_cur = 80;
    reg  [15:0] b_ae_cur = AE_MAX, b_ag_cur = 80;
    // 手动模式下由 TB 直接给出的"已生效值"（模拟 ae_set 里按键维护的目标）
    //   ⚠ 必须与 a_ae_cur 分开声明：`a_ae_cur` 已由下面的镜像 always 块驱动，
    //     再在任务里 procedural 赋值就是**多驱动**（Verilog 非法，仿真行为不确定）。
    reg  [15:0] a_man_ae = AE_MAX, a_man_ag = 80;
    reg  [15:0] b_man_ae = AE_MAX, b_man_ag = 80;
    reg         a_auto = 1, b_auto = 1;

    wire [15:0] a_ae, a_ag, b_ae, b_ag;
    wire [1:0]  a_dir, b_dir;
    wire [15:0] a_upd, b_upd;
    wire [7:0]  a_avg;
    wire [19:0] a_clip_o;
    wire        a_newf, b_newf;

    ae_ctrl #(
        .IMG_WIDTH(IMG_W), .IMG_HEIGHT(IMG_H),
        .TARGET_LUMA(TARGET_LUMA), .DZ_PCT(DZ_PCT),
        .AE_MIN(AE_MIN), .AE_MAX(AE_MAX),
        .AG_MIN(AG_MIN), .AG_MAX(16'd89),
        .AG_INIT(16'd80), .CLIP_PCT(2), .THROTTLE(2)
    ) dut_a (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_stats_sum(a_sum), .I_stats_clip(a_clip), .I_stats_tog(a_tog),
        .I_ae_cur(a_ae_cur), .I_ag_cur(a_ag_cur), .I_auto_en(a_auto),
        .O_ae(a_ae), .O_ag(a_ag),
        .O_avg_sum(), .O_avg_luma(a_avg), .O_clip_luma(a_clip_o),
        .O_dir(a_dir), .O_upd_cnt(a_upd), .O_new_frame(a_newf)
    );

    ae_ctrl #(
        .IMG_WIDTH(IMG_W), .IMG_HEIGHT(IMG_H),
        .TARGET_LUMA(TARGET_LUMA), .DZ_PCT(DZ_PCT),
        .AE_MIN(AE_MIN), .AE_MAX(AE_MAX),
        .AG_MIN(AG_MIN), .AG_MAX(16'd111),
        .AG_INIT(16'd80), .CLIP_PCT(2), .THROTTLE(2)
    ) dut_b (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_stats_sum(b_sum), .I_stats_clip(b_clip), .I_stats_tog(b_tog),
        .I_ae_cur(b_ae_cur), .I_ag_cur(b_ag_cur), .I_auto_en(b_auto),
        .O_ae(b_ae), .O_ag(b_ag),
        .O_avg_sum(), .O_avg_luma(), .O_clip_luma(),
        .O_dir(b_dir), .O_upd_cnt(b_upd), .O_new_frame(b_newf)
    );

    // ========================================================================
    //  传感器模型：复刻 SC500GainTbl 的编码
    //    索引 i  0..31 : 0x03(0x20+i)      粗 0x3 ⇒ 4 倍
    //    索引 i 32..63 : 0x07(0x20+i-32)   粗 0x7 ⇒ 8 倍
    //    索引 i 64..95 : 0x0F(0x20+i-64)   粗 0xF ⇒ 16 倍
    //    细增益 = 1 + (fine-0x20)/32
    //  ⇒ 增益是**分段线性**且段间**跳变 2 倍**的（4→8→16），
    //    这正是"AE 环路在段边界会不会大台阶"的关键，模型必须如实反映。
    // ========================================================================
    function integer gain_x1000;      // 增益 ×1000
        input [15:0] ag;
        integer idx, coarse, fine;
        begin
            idx = ag - AG_MIN;
            if (idx < 0)  idx = 0;
            if (idx > 95) idx = 95;
            if (idx <= 31) begin
                coarse = 3;  fine = 32 + idx;
            end else if (idx <= 63) begin
                coarse = 7;  fine = 32 + (idx - 32);
            end else begin
                coarse = 15; fine = 32 + (idx - 64);
            end
            gain_x1000 = (coarse + 1) * (1000 + ((fine - 32) * 1000) / 32);
        end
    endfunction

    // 参考点：AE=1990、AG=80（索引 64 → 0x0F20 → 16 倍）时平均亮度 = SCENE_LUMA_AT_DEFAULT
    //   ★ 用 ×256 定点先保留精度再除，避免 `(60×1990×20496)/…` 这种
    //     "先整除后相乘"把增益信息全丢掉（第一版就栽在这里：AG 89 和 80 算出同一个数）。
    function integer luma_of;
        input [15:0] ae, ag;
        integer ae_s, g, num;
        begin
            ae_s = (SCENE_LUMA_AT_DEFAULT * 256 * ae) / AE_MAX;   // ≤ 60*256 = 15360
            g    = gain_x1000(ag);                                // ≤ 31500
            num  = ae_s * g;                                      // ≤ 4.84e8 < 2^31 ✓
            luma_of = num / (16000 * 256);                        // /16倍 /256
            if (luma_of > 255) luma_of = 255;
            if (luma_of < 0)   luma_of = 0;
        end
    endfunction

    // ========================================================================
    //  驱动任务
    // ------------------------------------------------------------------------
    //  ★ 为什么每个用例要送 **2 帧**：
    //     ae_ctrl 里 `THROTTLE=2` ⇒ 节流计数器在 {0,1} 之间翻转，
    //     **每两个新统计帧才允许动作一次**（且"允许"的那一帧若不需要动，
    //     额度也照样清零）。所以"送 1 帧"能不能动**取决于进入时的计数器相位** ——
    //     第一版就是按"1 帧一动作"写的，结果所有断言的观测点都错开了一帧，
    //     日志看起来像"控制器全错"，实际上是**测试自己的时序假设错了**。
    //     送 2 帧 ⇒ 恰好 1 次动作机会，与相位无关。
    // ========================================================================
    task one_frame;
        input [31:0] s;
        input [19:0] c;
        begin
            @(negedge clk);
            a_sum = s; a_clip = c; a_tog = ~a_tog;
            b_sum = s; b_clip = c; b_tog = ~b_tog;
            repeat (5) @(posedge clk);
            // (!) 末尾必须再等一个 negedge 才返回：动作发生在最后一个 posedge 的
            //   非阻塞赋值里，若在同一个 posedge 的 active 区读 O_ae/O_ag，
            //   读到的是**更新前的值**（T10 就是这么误报的）。
            @(negedge clk);
            // ⚠ "提交"不再放在任务里做，改由下面的**连续镜像**进程完成 ——
            //   任务里"读一次 a_ag 再赋值"会**比动作早一拍**（动作发生在捕获后的
            //   下一拍），于是 `w_committed` 会无故变假、把下一次动作挡掉，
            //   表现为"送 2 帧却不动"。连续镜像才是真实 ae_set 的行为。
        end
    endtask

    // ---- 连续镜像：模拟 ae_set + I2C 拿到目标后**尽快提交** ----
    //   手动模式下停止镜像，让 TB 可以直接给出"手动目标"。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_ae_cur <= AE_MAX; a_ag_cur <= 80;
            b_ae_cur <= AE_MAX; b_ag_cur <= 80;
        end else begin
            if (a_auto) begin a_ae_cur <= a_ae; a_ag_cur <= a_ag; end
            else         begin a_ae_cur <= a_man_ae; a_ag_cur <= a_man_ag; end
            if (b_auto) begin b_ae_cur <= b_ae; b_ag_cur <= b_ag; end
            else         begin b_ae_cur <= b_man_ae; b_ag_cur <= b_man_ag; end
        end
    end

    // 送 2 帧 ⇒ 恰好 1 次动作机会
    task frame2;
        input [31:0] s;
        input [19:0] c;
        begin
            one_frame(s, c);
            one_frame(s, c);
        end
    endtask

    task do_reset;
        begin
            rst_n = 0;
            a_tog = 0; b_tog = 0; a_sum = 0; b_sum = 0; a_clip = 0; b_clip = 0;
            a_man_ae = AE_MAX; a_man_ag = 80; b_man_ae = AE_MAX; b_man_ag = 80;
            a_auto = 1; b_auto = 1;
            repeat (10) @(posedge clk);
            rst_n = 1;
            repeat (4) @(posedge clk);
        end
    endtask

    // ========================================================================
    //  组 1 断言辅助
    // ========================================================================
    integer ae_before, ag_before, upd_before;
    task t_start; begin
        ae_before = a_ae; ag_before = a_ag; upd_before = a_upd;
    end endtask

    task expect_none;
        input [511:0] name;
        begin
            if ((a_ae != ae_before) || (a_ag != ag_before)) begin
                $display("   [NG] %0s: 不应动作，但 AE %0d->%0d AG %0d->%0d",
                         name, ae_before, a_ae, ag_before, a_ag);
                err_cnt = err_cnt + 1;
            end else
                $display("   [ OK ] %0s: 保持 AE=%0d AG=%0d", name, a_ae, a_ag);
        end
    endtask

    task expect_ag;
        input integer d_ag;
        input [511:0] name;
        begin
            if ((a_ag - ag_before) != d_ag) begin
                $display("   [NG] %0s: AG %0d->%0d (期望 %0d)", name, ag_before, a_ag, d_ag);
                err_cnt = err_cnt + 1;
            end else if ((a_ae - ae_before) != 0) begin
                $display("   [NG] %0s: AE 不应变化，但 %0d->%0d", name, ae_before, a_ae);
                err_cnt = err_cnt + 1;
            end else
                $display("   [ OK ] %0s: AG %0d->%0d", name, ag_before, a_ag);
        end
    endtask

    task expect_ae;
        input integer d_ae;
        input [511:0] name;
        begin
            if ((a_ae - ae_before) != d_ae) begin
                $display("   [NG] %0s: AE %0d->%0d (期望 %0d)", name, ae_before, a_ae, d_ae);
                err_cnt = err_cnt + 1;
            end else if ((a_ag - ag_before) != 0) begin
                $display("   [NG] %0s: AG 不应变化，但 %0d->%0d", name, ag_before, a_ag);
                err_cnt = err_cnt + 1;
            end else
                $display("   [ OK ] %0s: AE %0d->%0d", name, ae_before, a_ae);
        end
    endtask

    initial begin
        $display("");
        $display("============================================================");
        $display(" tb_ae_ctrl : 组 1 开环决策断言");
        $display("============================================================");
        do_reset;

        // ---------------- T1 死区 ----------------
        $display("  -- T1 死区（sum 恰为目标）--");
        t_start; frame2(SUM_MID, 20'd0);
        expect_none("T1 dead-zone: hold");

        $display("  -- T1b 死区边界内（+2%%）--");
        t_start; frame2(SUM_MID + (SUM_MID * 2) / 100, 20'd0);
        expect_none("T1b inside +2%: hold");

        // ---------------- T2 偏暗 + AE 到顶 ⇒ 加 AG ----------------
        //   sum = 40*PIX = 36.9M < SUM_FAR_LO(51.6M) ⇒ far ⇒ 步长 8
        //   AE=1990 已在顶 ⇒ 只能动 AG；S_dir 仍为 0 ⇒ 无反转阻尼 ⇒ 恰好 +8
        $display("  -- T2 偏暗且 AE 到顶 ⇒ 加 AG --");
        t_start; frame2(32'd40 * PIX, 20'd0);
        expect_ag(+8, "T2 dark+AE at max => AG +8");

        // ---------------- T9 方向反转阻尼 ----------------
        //   上一次方向是"变亮"(1)，本次要"变暗" ⇒ 反转 ⇒ 步长减半
        //   sum = 250*PIX = 230.4M > SUM_FAR_HI(206.4M) ⇒ far ⇒ 8 → 反转后 4
        $display("  -- T9a 反转阻尼（变亮后立刻转变暗，far 8 -> 4）--");
        t_start; frame2(32'd250 * PIX, 20'd0);
        expect_ag(-4, "T9a direction reverse => step halved to 4");
        $display("  -- T9b 同方向（继续变暗，不再减半）--");
        t_start; frame2(32'd250 * PIX, 20'd0);
        expect_ag(-8, "T9b same direction => step back to 8");

        // ---------------- T3 偏亮（mid 档）⇒ 变暗 ----------------
        //   sum = 200*PIX = 184.3M：> SUM_MID_HI(154.8M) 但 < SUM_FAR_HI ⇒ mid ⇒ 2
        //   S_dir 仍为 2（上次也是变暗）⇒ 无反转 ⇒ 恰好 -2
        $display("  -- T3 偏亮（mid 档）⇒ 变暗 -2 --");
        t_start; frame2(32'd200 * PIX, 20'd0);
        expect_ag(-2, "T3 bright, mid tier => step 2");

        // ---------------- T4 ★ 高光保护 ----------------
        //   均值偏暗（应加亮），但过曝像素 60000 > 2%（18432）⇒ 必须变暗
        //   sum = 40*PIX ⇒ far ⇒ 8；方向从"变暗"到"变暗"（保护也是暗）⇒ 无反转 ⇒ -8
        $display("  -- T4 高光保护（均值偏暗 + 过曝超限）--");
        t_start; frame2(32'd40 * PIX, 20'd60000);
        expect_ag(-8, "T4 highlight protect: force darken");
        if (a_dir != 2'd3) begin
            $display("   [NG] T4: O_dir=%0d 期望 3（高光保护降）", a_dir);
            err_cnt = err_cnt + 1;
        end else
            $display("   [ OK ] T4: O_dir=3（高光保护）");

        // ---------------- T5 手动模式 ----------------
        $display("  -- T5 手动模式：只跟随已生效值 --");
        a_auto = 0;
        repeat (2) @(posedge clk);
        a_man_ae = 16'd500; a_man_ag = 16'd50;
        repeat (4) @(posedge clk);
        if ((a_ae !== 16'd500) || (a_ag !== 16'd50)) begin
            $display("   [NG] T5: 手动模式输出应为已生效值 (500,50)，实为 (%0d,%0d)", a_ae, a_ag);
            err_cnt = err_cnt + 1;
        end else
            $display("   [ OK ] T5: 跟随已生效值 (%0d,%0d)", a_ae, a_ag);
        t_start; frame2(32'd40 * PIX, 20'd0);
        expect_none("T5 manual: no command");

        $display("  -- T5b 切回自动 ⇒ 从已生效值无缝衔接 --");
        a_auto = 1;
        repeat (4) @(posedge clk);
        if (abs_i(a_ae - 500) > 2 || abs_i(a_ag - 50) > 2) begin
            $display("   [NG] T5b: 应从 (500,50) 起算，实为 (%0d,%0d)", a_ae, a_ag);
            err_cnt = err_cnt + 1;
        end else
            $display("   [ OK ] T5b: 从已生效值起算 (%0d,%0d)", a_ae, a_ag);

        // ---------------- T10 曝光优先（AE 未到顶 ⇒ 只加 AE）----------------
        //   此刻内部 AE 目标 = 500（手动时跟随进来的），远未到顶
        //   sum = 40*PIX ⇒ far ⇒ AE 步长 256；S_dir 被手动模式清 0 ⇒ 无反转
        $display("  -- T10 曝光优先：AE=500 未到顶 ⇒ 只加 AE（far 256）--");
        t_start; frame2(32'd40 * PIX, 20'd0);
        expect_ae(+256, "T10 exposure-first: AE only");

        // ---------------- T11 ★ 上限饱和（2026-09-23 上板照片定位出的真 bug 的回归）----------------
        //   构造"接近上限 + 大步长"这个**原有用例恰好避开**的边界：
        //     S_ag_t = 88（< AG_MAX=89 ⇒ 判定"能动"）而 far 步长 = 8
        //     修好前：目标变成 96（越界）；修好后：饱和到 89
        //   ⚠ 原用例为什么没抓到：组 2 闭环里 AG 涨到 89 时步长恰好是 1；
        //     组 1 的 T2 是 80→88（88 ≤ 89）。**边界差一点就不越界** ——
        //     这类 bug 只能靠精确构造边界来暴露。
        $display("  -- T11 saturation at AG_MAX (88 + far 8 must clamp to 89, not 96) --");
        dut_a.S_ae_t = 16'd1990;          // AE 顶在上限 ⇒ 只能动 AG
        dut_a.S_ag_t = 16'd88;
        a_man_ae = 16'd1990; a_man_ag = 16'd88;
        repeat (3) @(posedge clk);
        t_start; frame2(32'd40 * PIX, 20'd0);     // 偏暗 ⇒ 加 AG（far ⇒ 步长 8）
        if (a_ag > 16'd89) begin
            $display("   [NG] T11: AG 越界到 %0d（应饱和在 89）—— 钳位失效！", a_ag);
            err_cnt = err_cnt + 1;
        end else if (a_ag != 16'd89) begin
            $display("   [NG] T11: AG=%0d，期望饱和到 89", a_ag);
            err_cnt = err_cnt + 1;
        end else
            $display("   [ OK ] T11: AG 饱和在 89（未越界到 96）");

        // ---------------- T12 ★ 下限饱和 / 不下溢 ----------------
        //   S_ae_t = 200、AG 已在下限 16 ⇒ 变暗只能走 AE，far 步长 256
        //     修好前：200-256 在 16 位无符号下**下溢成 65480**（非法曝光，且闭环冻结）
        //     修好后：饱和停在 AE_MIN = 2
        $display("  -- T12 no underflow (200 - far 256 must clamp to AE_MIN, not 65480) --");
        dut_a.S_ae_t = 16'd200;
        dut_a.S_ag_t = 16'd16;            // AG 已到下限 ⇒ 只能动 AE
        dut_a.S_dir  = 2'd2;              // ★ 方向也设成"变暗" ⇒ 避免反转阻尼把步长减半
                                          //   （第一次没设，得到 200-128=72 —— 那其实是**正确**行为，
                                          //     是我期望值算漏了阻尼；这也说明阻尼确实在工作）
        a_man_ae = 16'd200; a_man_ag = 16'd16;
        repeat (3) @(posedge clk);
        t_start; frame2(32'd250 * PIX, 20'd0);    // 偏亮 ⇒ 变暗（far ⇒ AE 步长 256，无反转）
        if (a_ae > 16'd1990) begin
            $display("   [NG] T12: AE 下溢成 %0d（非法曝光！）—— 钳位失效！", a_ae);
            err_cnt = err_cnt + 1;
        end else if (a_ae != 16'd2) begin
            $display("   [NG] T12: AE=%0d，期望饱和到 AE_MIN=2", a_ae);
            err_cnt = err_cnt + 1;
        end else
            $display("   [ OK ] T12: AE 饱和到 2（未下溢成 65480）");

        // ---------------- T6 节流 ----------------
        //   连送 4 帧：THROTTLE=2 ⇒ 只允许动作 2 次（不节流的话会是 4 次）
        $display("  -- T6 节流（连送 4 帧，只允许动作 2 次）--");
        t_start;
        one_frame(32'd40 * PIX, 20'd0);
        one_frame(32'd40 * PIX, 20'd0);
        one_frame(32'd40 * PIX, 20'd0);
        one_frame(32'd40 * PIX, 20'd0);
        if (a_upd != upd_before + 2) begin
            $display("   [NG] T6: 4 帧应恰好下发 2 次，实为 %0d 次", a_upd - upd_before);
            err_cnt = err_cnt + 1;
        end else
            $display("   [ OK ] T6: 4 帧恰好下发 2 次（未被节流的话会是 4 次）");
    end

    // ========================================================================
    //  组 2：闭环收敛（含 1 帧传感器响应延迟）
    // ========================================================================
    integer i, fb, NF = 200;
    integer la_p, lb_p, conv_a, conv_b, upd_a, upd_b;

    initial begin
        #3000;                     // 等组 1 跑完（组 1 只有几百 ns）

        $display("");
        $display("============================================================");
        $display(" tb_ae_ctrl : 组 2 闭环收敛（独立传感器模型 + 1 帧延迟）");
        $display("   场景假设：默认 AE=%0d / AG=80 时平均亮度 = %0d（偏暗）",
                 AE_MAX, SCENE_LUMA_AT_DEFAULT);
        $display("   增益表复刻：索引 0..31/32..63/64..95 = 粗增益 4/8/16 倍 + 细增益");
        $display("   目标 = %0d ±%0d%%", TARGET_LUMA, DZ_PCT);
        $display("============================================================");

        do_reset;
        conv_a = -1; conv_b = -1;

        for (fb = 0; fb < NF; fb = fb + 1) begin
            // 本帧**观测到**的亮度 = 由上一帧的 (AE,AG) 决定（1 帧延迟）
            la_p = luma_of(a_ae, a_ag);
            lb_p = luma_of(b_ae, b_ag);

            @(negedge clk);
            a_sum = la_p * PIX; a_clip = 20'd0; a_tog = ~a_tog;
            b_sum = lb_p * PIX; b_clip = 20'd0; b_tog = ~b_tog;
            repeat (4) @(posedge clk);
            // 已生效值由连续镜像进程负责（不要在这里 procedural 赋值：多驱动）
            repeat (2) @(posedge clk);

            if (conv_a < 0 && abs_i(la_p - TARGET_LUMA) * 100 <= TARGET_LUMA * DZ_PCT)
                conv_a = fb;
            if (conv_b < 0 && abs_i(lb_p - TARGET_LUMA) * 100 <= TARGET_LUMA * DZ_PCT)
                conv_b = fb;

            if (fb < 16 || fb % 25 == 0)
                $display("   f%-3d | A: AE=%-4d AG=%-3d L=%-3d upd=%-3d | B: AE=%-4d AG=%-3d L=%-3d upd=%-3d",
                         fb, a_ae, a_ag, la_p, a_upd, b_ae, b_ag, lb_p, b_upd);
        end
        repeat (6) @(posedge clk);

        $display("");
        $display("  ---- 收敛结论 ----");
        $display("   A(AG_MAX= %0d) 终态 AE=%0d AG=%0d 亮度=%0d  （目标 %0d）",
                 AG_MAX_A, a_ae, a_ag, luma_of(a_ae, a_ag), TARGET_LUMA);
        $display("   B(AG_MAX= %0d) 终态 AE=%0d AG=%0d 亮度=%0d",
                 AG_MAX_B, b_ae, b_ag, luma_of(b_ae, b_ag));
        if (conv_a < 0)
            $display("   [!!] A 未进死区（增益上限 %0d 不够）", AG_MAX_A);
        else
            $display("   [OK] A 第 %0d 帧进入死区", conv_a);
        if (conv_b < 0) begin
            $display("   [NG] B 未进死区 ⇒ 「补全增益表」方案在本场景下**不成立**，需数字增益");
            err_cnt = err_cnt + 1;
        end else
            $display("   [OK] B 第 %0d 帧进入死区", conv_b);

        // ---- 抗振荡：收敛后 40 帧内不得再动 ----
        $display("");
        $display("  ---- 抗振荡（收敛后再跑 40 帧）----");
        upd_a = a_upd; upd_b = b_upd;
        for (i = 0; i < 40; i = i + 1) begin
            la_p = luma_of(a_ae, a_ag);
            lb_p = luma_of(b_ae, b_ag);
            @(negedge clk);
            a_sum = la_p * PIX; a_tog = ~a_tog;
            b_sum = lb_p * PIX; b_tog = ~b_tog;
            repeat (4) @(posedge clk);
            // 已生效值由连续镜像进程负责（不要在这里 procedural 赋值：多驱动）
            repeat (2) @(posedge clk);
        end
        if (a_upd != upd_a) begin
            $display("   [NG] A 收敛后仍在动作：upd %0d -> %0d（振荡）", upd_a, a_upd);
            err_cnt = err_cnt + 1;
        end else
            $display("   [ OK ] A 静默（upd 保持 %0d，AG=%0d）  <= 这就是「AG 上限不够 ⇒ 安静饱和」",
                     a_upd, a_ag);
        if (b_upd != upd_b) begin
            $display("   [NG] B 收敛后仍在动作：upd %0d -> %0d（振荡）", upd_b, b_upd);
            err_cnt = err_cnt + 1;
        end else
            $display("   [ OK ] B 静默（upd 保持 %0d，AG=%0d）", b_upd, b_ag);

        // ---- ★ 平均亮度核对（P6 时序修复后，avg 搬到本模块算） ----
        //   做法：给一个**已知的 ΣY**，检查 O_avg_luma 是否等于独立算出的均值。
        //   为什么要专门测这一段：avg 从 luma_stats（60 MHz 域）搬到本模块（24 MHz 域）
        //   是为了修 ISP 域的时序（实测该域 Fmax 77.954 → 60.361 MHz），
        //   搬完之后必须重新证明它算得对 —— 而且这里能覆盖到**穷举 0..255 之外**的
        //   真实整帧量级（ΣY ≈ 1e8）。
        $display("");
        $display("  ---- avg 核对（avg = ((sum>>10)*18642)>>24，独立算好期望）----");
        begin : avg_chk
            integer k2, exp_avg, got_avg;
            //  ΣY = 921600 * v  ⇒  avg 应当 = v（或 v 附近 ±1）
            for (k2 = 0; k2 < 5; k2 = k2 + 1) begin
                case (k2)
                    0: exp_avg = 112;
                    1: exp_avg = 60;
                    2: exp_avg = 200;
                    3: exp_avg = 255;
                    default: exp_avg = 7;
                endcase
                @(negedge clk);
                a_sum = exp_avg * PIX; a_clip = 20'd0; a_tog = ~a_tog;
                b_sum = exp_avg * PIX; b_clip = 20'd0; b_tog = ~b_tog;
                repeat (4) @(posedge clk);
                //   ⚠ avg 用**上一帧**已寄存的 ΣY 算 ⇒ 要在**下一帧**才反映本帧的 ΣY。
                //     所以这里"再送一帧同样的值"，第二帧读到的才是本值。
                @(negedge clk);
                a_sum = exp_avg * PIX; a_tog = ~a_tog;
                b_sum = exp_avg * PIX; b_tog = ~b_tog;
                repeat (4) @(posedge clk);
                @(negedge clk);
                got_avg = a_avg;
                if (abs_i(got_avg - exp_avg) > 1) begin
                    $display("   [NG] avg: ΣY=%0d 的均值 %0d 期望 %0d（容差 1）",
                             exp_avg * PIX, got_avg, exp_avg);
                    err_cnt = err_cnt + 1;
                end else
                    $display("   [ OK ] avg: ΣY=%0d -> O_avg_luma=%0d（期望 %0d）",
                             exp_avg * PIX, got_avg, exp_avg);
                repeat (4) @(posedge clk);
            end
        end


        $display("");
        if (err_cnt == 0) $display(" ==== PASS ====");
        else              $display(" ==== FAIL （%0d 项）====", err_cnt);
        $display("============================================================");
        $finish;
    end

    initial begin
        #20_000_000;
        $display(" [NG] timeout");
        $finish;
    end

endmodule
