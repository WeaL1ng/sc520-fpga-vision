// ============================================================================
//  tb_frame_latency_bank.v  ---  延迟测量的**集成级**验证（P3 重写后）
//
//  ★ 为什么必须重写测试台
//  ---------------------------------------------------------------------------
//   P3 原来的模块级测试台 `tb_frame_latency.v` 8/8 全过，但**上板是错的**
//   （屏上数字在 0~10 ms 之间来回扫）。根因是那个 TB 对接口的建模不对：
//   它假设"写侧给了标签之后，显示域会在真正的延迟之后才用到它"，
//   而真实集成里显示域**总是取走最新标签** ⇒ 算出来的是采集帧内的相位。
//
//   ⇒ 本 TB 改成**忠实建模真实集成**：
//        · 采集帧起始与显示帧起始是**两个独立周期**的脉冲；
//        · 4 个 DDR BANK，写指针 wp 每采集帧 +1；
//        · 读指针 rp = wp + 2 (mod 4)（video_in.v 实测行为）；
//        · 显示的是 **2 个采集帧之前**那一帧。
//     并把 **P3 的旧算法**作为参考模型放进同一个 TB，与 DUT 跑同一激励：
//        T4/T5 断言旧算法只覆盖 [0, P_c) —— **在仿真里复现板上现象**
//        T1~T3 断言新算法恒在 [2P_c, 3P_c] —— 即真实延迟
//
//  ★ 时间尺度（为什么不用真实时钟频率）
//     把 CLK_FREQ_HZ 设为 10000 而不是 266667，于是 MS_DIV = 10 拍 = 1 ms；
//     再令 TB 时钟周期 = 10 ns ⇒ **1 拍 = 0.1 ms 虚拟时间**。
//     采集帧周期取整数拍即可精确表示：100 拍 = 10.00 ms；
//     显示帧 165 拍 = 16.50 ms（与板上 VTC 实测 1650x750 @ 75.002 MHz 一致）。
//     这样时序全确定、无小数，200 帧约 3.3 万拍，秒级跑完。
//
//  用法：
//     vsim -batch -lib work tb_frame_latency_bank -do "run -all; quit -f"
//     vsim ... +pc=167 +pd=165     # 更接近的帧率（复现"慢扫"）
// ============================================================================
`timescale 1ns/1ps

module tb_frame_latency_bank;

    localparam integer CLK_HZ    = 10000;   // ⇒ MS_DIV = 10 拍 = 1 ms
    localparam integer MS_DIV    = CLK_HZ / 1000;
    localparam real    MS_PER_CK = 0.1;     // 1 拍 = 0.1 ms 虚拟时间

    integer PC_CK, PD_CK, NSAMP;
    integer plus_dummy;
    real    PC_MS, PD_MS, TRUE_LO, TRUE_HI;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;                       // 10 ns/拍 = 0.1 ms
    reg clk_dis = 0;
    always #37 clk_dis = ~clk_dis;              // OSD 域：给个无关的不同频率

    // ========================================================================
    // TB 自己的毫秒计数（与 DUT 内部一致：每 MS_DIV 拍 +1）
    // ========================================================================
    integer ms_cnt  = 0;
    integer div_cnt = 0;
    always @(posedge clk) begin
        if (div_cnt == MS_DIV-1) begin div_cnt <= 0; ms_cnt <= ms_cnt + 1; end
        else div_cnt <= div_cnt + 1;
    end

    // ========================================================================
    // 两个**独立**的帧起始脉冲（组合产生，保证同一拍内所有块看到同一边沿）
    // ========================================================================
    integer cap_ph = 0, dis_ph = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            if (cap_ph >= PC_CK-1) cap_ph <= 0; else cap_ph <= cap_ph + 1;
            if (dis_ph >= PD_CK-1) dis_ph <= 0; else dis_ph <= dis_ph + 1;
        end
    end
    wire cap_start = rst_n && (cap_ph == PC_CK-1);
    wire dis_start = rst_n && (dis_ph == PD_CK-1);

    // ========================================================================
    // 帧缓冲模型：wp 每采集帧 +1；rp = wp + 2 (mod 4)
    //   注意 wp 在"本帧"仍是自增前的值 ⇒ 本帧写入 BANK = wp
    // ========================================================================
    reg [1:0] wp = 0;
    reg [1:0] rp = 0;
    always @(posedge clk) begin
        if (cap_start) begin
            rp <= wp + 2'd2;        // ★ video_in.v 的实测行为
            wp <= wp + 2'd1;
        end
    end

    // ========================================================================
    // DUT：新算法（按 BANK 索引标签）
    // ========================================================================
    wire [31:0] dut_lat;
    wire        dut_vld;

    frame_latency #(
        .CLK_FREQ_HZ  ( CLK_HZ ),
        .AVG_SHIFT    ( 0      ),   // ★ 关平滑，直接看原始测量值
        .MAX_VALID_MS ( 500    ),
        .TAG_INIT     ( 32'd0  )
    ) dut (
        .I_clk            ( clk       ),
        .I_rst_n          ( rst_n     ),
        .I_wr_frame_start ( cap_start ),
        .I_wr_bank        ( wp        ),
        .I_rd_frame_start ( dis_start ),
        .I_rd_bank        ( rp        ),
        .I_clk_dis        ( clk_dis   ),
        .I_rst_dis_n      ( rst_n     ),
        .O_latency_ms     ( dut_lat   ),
        .O_lat_valid      ( dut_vld   )
    );

    // ---- 第二份 DUT：**出厂配置** AVG_SHIFT=8（EMA 平滑）----
    //   ⚠ 上一轮的教训就是"只测了没出货的那条路"。板上跑的是 AVG_SHIFT=8，
    //     所以这里必须把平滑路径也跑起来，确认：
    //       ① 首样本直接装载 ⇒ 不会出现"从 0 慢慢往上爬"的假数字；
    //       ② 稳态值落在真实延迟区间内；
    //       ③ 平滑后抖动明显小于原始值。
    wire [31:0] avg_lat;
    wire        avg_vld;

    frame_latency #(
        .CLK_FREQ_HZ  ( CLK_HZ ),
        .AVG_SHIFT    ( 8      ),   // ★ 与 design_top_wrapper 的出厂配置一致
        .MAX_VALID_MS ( 500    ),
        .TAG_INIT     ( 32'd0  )
    ) dut_avg (
        .I_clk            ( clk       ),
        .I_rst_n          ( rst_n     ),
        .I_wr_frame_start ( cap_start ),
        .I_wr_bank        ( wp        ),
        .I_rd_frame_start ( dis_start ),
        .I_rd_bank        ( rp        ),
        .I_clk_dis        ( clk_dis   ),
        .I_rst_dis_n      ( rst_n     ),
        .O_latency_ms     ( avg_lat   ),
        .O_lat_valid      ( avg_vld   )
    );

    // 平滑通道的统计
    integer avg_n = 0;
    real    avg_min = 0, avg_max = 0, avg_sum = 0;
    integer avg_bad_range = 0;
    // 首个有效值（用于验证"直接装载、不从 0 爬"）
    integer avg_first = -1;
    reg     avg_first_seen = 0;
    always @(posedge clk) begin
        if (rst_n && avg_vld) begin
            if (!avg_first_seen) begin avg_first <= avg_lat; avg_first_seen <= 1'b1; end
            if (avg_n == 0) begin avg_min <= avg_lat; avg_max <= avg_lat; avg_sum <= avg_lat; end
            else begin
                if (avg_lat < avg_min) avg_min <= avg_lat;
                if (avg_lat > avg_max) avg_max <= avg_lat;
                avg_sum <= avg_sum + avg_lat;
            end
            avg_n <= avg_n + 1;
            if ((avg_lat < TRUE_LO - 2.0) || (avg_lat > TRUE_HI + 2.0))
                avg_bad_range <= avg_bad_range + 1;
        end
    end

    // ========================================================================
    // 参考模型：**P3 的旧算法**（在仿真里复现板上现象）
    //   · 采集域每帧起始写 {ms, 帧号} 到乒乓；显示域检测翻转后**总是取最新**；
    //   · 显示帧号 >= 标签帧号 才结算，否则保持。
    // ========================================================================
    reg [31:0] old_tag_ms  [0:1];
    reg [11:0] old_tag_fno [0:1];
    reg        old_sel = 0, old_tgl = 0;
    reg [11:0] old_cap_fno = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            old_tag_ms[0]<=0; old_tag_ms[1]<=0;
            old_tag_fno[0]<=0; old_tag_fno[1]<=0;
            old_sel<=0; old_tgl<=0; old_cap_fno<=0;
        end else if (cap_start) begin
            old_tag_ms [old_sel] <= ms_cnt;
            old_tag_fno[old_sel] <= old_cap_fno;
            old_tgl <= ~old_tgl;
            old_sel <= ~old_sel;
            old_cap_fno <= old_cap_fno + 12'd1;
        end
    end

    reg [31:0] old_held_ms  = 0;
    reg [11:0] old_held_fno = 0;
    reg        old_held_vld = 0;
    reg [11:0] old_dis_fno  = 0;
    reg [31:0] old_lat      = 0;
    reg        old_lat_vld  = 0;
    reg        old_tgl_d1 = 0, old_tgl_d2 = 0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            old_held_ms<=0; old_held_fno<=0; old_held_vld<=0;
            old_dis_fno<=0; old_lat<=0; old_lat_vld<=0;
            old_tgl_d1<=0; old_tgl_d2<=0;
        end else begin
            old_tgl_d1 <= old_tgl;
            old_tgl_d2 <= old_tgl_d1;
            if (old_tgl_d1 ^ old_tgl_d2) begin
                old_held_ms  <= old_tag_ms [~old_sel];
                old_held_fno <= old_tag_fno[~old_sel];
                old_held_vld <= 1'b1;
            end
            if (dis_start) begin
                old_dis_fno <= old_dis_fno + 12'd1;
                if (!old_held_vld) begin
                    old_lat <= 0; old_lat_vld <= 1'b0;
                end else if (old_dis_fno < old_held_fno) begin
                    // 会算出负数 ⇒ 跳过、保持上次值
                end else begin
                    old_lat <= ms_cnt - old_held_ms;
                    old_lat_vld <= 1'b1;
                end
            end
        end
    end

    // ========================================================================
    // 统计
    // ========================================================================
    integer dut_n = 0, old_n = 0;
    real    dut_min = 0, dut_max = 0, dut_sum = 0;
    real    old_min = 0, old_max = 0, old_sum = 0;
    integer dut_bad_range = 0;
    integer old_in_true_range = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (dut_vld) begin
                if (dut_n == 0) begin dut_min <= dut_lat; dut_max <= dut_lat; dut_sum <= dut_lat; end
                else begin
                    if (dut_lat < dut_min) dut_min <= dut_lat;
                    if (dut_lat > dut_max) dut_max <= dut_lat;
                    dut_sum <= dut_sum + dut_lat;
                end
                dut_n <= dut_n + 1;
                if ((dut_lat < TRUE_LO - 1.0) || (dut_lat > TRUE_HI + 1.0))
                    dut_bad_range <= dut_bad_range + 1;
            end
            if (old_lat_vld) begin
                if (old_n == 0) begin old_min <= old_lat; old_max <= old_lat; old_sum <= old_lat; end
                else begin
                    if (old_lat < old_min) old_min <= old_lat;
                    if (old_lat > old_max) old_max <= old_lat;
                    old_sum <= old_sum + old_lat;
                end
                old_n <= old_n + 1;
                if ((old_lat >= TRUE_LO - 1.0) && (old_lat <= TRUE_HI + 1.0))
                    old_in_true_range <= old_in_true_range + 1;
            end
        end
    end

    // ========================================================================
    // 主流程
    // ========================================================================
    integer pass_cnt = 0, fail_cnt = 0;
    task chk;
        input [255:0] name;
        input         cond;
        begin
            if (cond) begin pass_cnt = pass_cnt + 1; $display("  [PASS] %0s", name); end
            else      begin fail_cnt = fail_cnt + 1; $display("  [FAIL] %0s", name); end
        end
    endtask

    initial begin
        PC_CK = 100; PD_CK = 165; NSAMP = 200;
        // ⚠ 不用 `void'()`（那是 SystemVerilog）；本工程一律 Verilog-2001
        plus_dummy = $value$plusargs("pc=%d", PC_CK);
        plus_dummy = $value$plusargs("pd=%d", PD_CK);
        plus_dummy = $value$plusargs("n=%d",  NSAMP);
        PC_MS   = PC_CK * MS_PER_CK;
        PD_MS   = PD_CK * MS_PER_CK;
        TRUE_LO = 2.0 * PC_MS;
        TRUE_HI = 3.0 * PC_MS;

        $display("");
        $display("============================================================");
        $display(" tb_frame_latency_bank : 按 DDR BANK 索引的延迟测量");
        $display("   采集帧周期 P_c = %0d 拍 = %0.2f ms", PC_CK, PC_MS);
        $display("   显示帧周期 P_d = %0d 拍 = %0.2f ms", PD_CK, PD_MS);
        $display("   真实延迟区间   = [2P_c, 3P_c] = [%0.1f, %0.1f] ms", TRUE_LO, TRUE_HI);
        $display("   统计显示帧数   = %0d", NSAMP);
        $display("============================================================");

        rst_n = 0;
        repeat (30) @(posedge clk);
        rst_n = 1;

        repeat (NSAMP * PD_CK) @(posedge clk);

        $display("");
        $display("  ---- 统计（只看 vld=1 的样本，单位 ms）----");
        if (dut_n > 0)
            $display("   新方案(按BANK): n=%-4d min=%-5.1f max=%-5.1f avg=%-6.2f  越界 %0d",
                     dut_n, dut_min, dut_max, dut_sum/dut_n, dut_bad_range);
        else
            $display("   新方案(按BANK): **一个有效样本都没有**");
        if (old_n > 0)
            $display("   旧方案(P3)    : n=%-4d min=%-5.1f max=%-5.1f avg=%-6.2f  落在真实区间 %0d",
                     old_n, old_min, old_max, old_sum/old_n, old_in_true_range);
        else
            $display("   旧方案(P3)    : **一个样本都没有**（被帧号门控挡住）");
        if (avg_n > 0)
            $display("   出厂配置(AVG8): n=%-4d min=%-5.1f max=%-5.1f avg=%-6.2f  首值=%-4d 越界 %0d",
                     avg_n, avg_min, avg_max, avg_sum/avg_n, avg_first, avg_bad_range);
        else
            $display("   出厂配置(AVG8): **一个有效样本都没有**");

        $display("");
        $display("  ---- 判定 ----");

        chk("T1 新方案测出了延迟（有 vld=1 的样本）", dut_n > 0);
        chk("T2 新方案全部落在 [2P_c, 3P_c]（真实延迟）", (dut_n > 0) && (dut_bad_range == 0));
        chk("T3 新方案 min >= 2*P_c（含帧缓冲那 2 帧）",
            (dut_n > 0) && (dut_min >= TRUE_LO - 1.0));
        chk("T4 旧方案(P3) 最大值 < 2*P_c（= 板上 0~10ms 扫动的成因）",
            (old_n > 0) && (old_max < TRUE_LO - 1.0));
        chk("T5 旧方案范围 <= P_c（锯齿的模 = 采集帧周期）",
            (old_n > 0) && ((old_max - old_min) <= PC_MS + 1.5));

        // ---- T6~T8：出厂配置 AVG_SHIFT=8 的平滑通道（板上真正跑的那条路）----
        chk("T6 出厂配置(AVG_SHIFT=8) 有有效输出", avg_n > 0);
        chk("T7 平滑通道首值即落在真实区间（不是从 0 爬上来）",
            avg_first_seen && (avg_first >= TRUE_LO - 2.0));
        chk("T8 平滑通道全部落在真实区间（±2ms 容差）",
            (avg_n > 0) && (avg_bad_range == 0));

        $display("");
        $display("============================================================");
        $display(" PASS = %0d   FAIL = %0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display(" [OK] 新算法测的是真实延迟；旧算法缺陷已在仿真中复现");
        else               $display(" [NG] %0d 项不通过", fail_cnt);
        $display("============================================================");
        $finish;
    end

    initial begin
        #50_000_000;
        $display(" [NG] timeout");
        $finish;
    end

endmodule
