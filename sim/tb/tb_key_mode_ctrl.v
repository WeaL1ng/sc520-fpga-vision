// ============================================================================
//  tb_key_mode_ctrl.v -- key_mode_ctrl 的功能自检测试
// ----------------------------------------------------------------------------
//  被测  : key_mode_ctrl  (lab_ex4_all_features / hdl_source/key_mode_ctrl.v)
//  目的  : 验证短按/长按语义、AE 门控、复位行为
//
//  ★ 2026-09-20 红线1 改造后的期望行为（本 TB 已同步更新）：
//     KEY0 短按：O_mode **依次循环** 0 原图 -> 1 灰度 -> 2 二值化 -> 3 反色 -> 0
//     KEY1 短按：**不改模式**（该键专职 AE 调节）
//     两键长按：均不改模式，且 O_btn_ae 对应位拉低（ae_set 可见）
//    改造前是"KEY0 翻 bit0 / KEY1 翻 bit1"的独立翻转，故 T1/T2/T4/T5 已重写。
//
//  设计要点
//  --------
//  * **用缩短的时间参数**（CLK 50kHz / 去抖 10us / 长按 100us），
//    使整份仿真在 ~5 ms 仿真时间内跑完，而不是真机的 500ms。
//    逻辑与参数无关，所以缩短不影响结论。
//  * **自检**：每个用例用 check_int 比对，末尾打印 PASS/FAIL 与失败计数，
//    便于在无 GUI 的批处理模式下直接判定（可用 $fatal 让 vsim 返回非零）。
//
//  运行
//  ----
//    cd sim\tb
//    vlib work
//    vlog -work work ..\..\rtl_vendor\anlogic_example\lab_ex4_all_features_SC500_720P\lab_ex4_all_features\user_source\hdl_source\key_mode_ctrl.v
//    vlog -work work tb_key_mode_ctrl.v
//    vsim -c -work work tb_key_mode_ctrl -do "run -all; quit -f"
//
//  期望输出末尾：  *** ALL TESTS PASSED ***
// ============================================================================
`timescale 1ns/1ps

module tb_key_mode_ctrl;

    // ---------------------------------------------------------------- 参数
    // 缩短版：50 kHz 时钟 → 周期 20 us
    //   模块内部按 (CLK_FREQ_HZ/1000)*XXX_MS 算周期，
    //   XXX_MS 以"ms"为整数单位。
    //   这里取 DEBOUNCE_MS=1 → 50 拍；LONGPRESS_MS=2 → 100 拍，
    //   使整份仿真在 ~5 ms 仿真时间内跑完（真机是 500ms）。
    //   逻辑与参数无关，缩短不影响结论。
    localparam integer CLK_FREQ_HZ     = 50_000;
    localparam integer TB_DEBOUNCE_MS  = 1;
    localparam integer TB_LONGPRESS_MS = 2;

    localparam real    CLK_PERIOD     = 1_000_000_000.0 / CLK_FREQ_HZ;  // ns
    localparam integer DEB_CYC        = (CLK_FREQ_HZ/1000)*TB_DEBOUNCE_MS;   // 50
    localparam integer LP_CYC         = (CLK_FREQ_HZ/1000)*TB_LONGPRESS_MS;  // 100

    // ---------------------------------------------------------------- 信号
    reg         I_clk   = 1'b0;
    reg         I_rst_n = 1'b0;
    reg  [1:0]  I_button = 2'b11;
    wire [2:0]  O_mode;
    wire [1:0]  O_btn_ae;
    wire        O_auto_tog;      // ★ P6 新增：短按 KEY2 → AE 自动/手动切换脉冲

    integer fail_cnt = 0;
    integer pass_cnt = 0;

    // ---------------------------------------------------------------- DUT
    key_mode_ctrl #(
        .CLK_FREQ_HZ  ( CLK_FREQ_HZ     ),
        .DEBOUNCE_MS  ( TB_DEBOUNCE_MS  ),
        .LONGPRESS_MS ( TB_LONGPRESS_MS )
    ) u_dut (
        .I_clk    ( I_clk    ),
        .I_rst_n  ( I_rst_n  ),
        .I_button ( I_button ),
        .O_mode   ( O_mode   ),
        .O_btn_ae ( O_btn_ae ),
        .O_auto_tog ( O_auto_tog )
    );

    always #(CLK_PERIOD/2.0) I_clk = ~I_clk;

    // ---------------------------------------------------------------- 检查
    task check_int;
        input [8*48-1:0] name;
        input integer    got;
        input integer    exp;
        begin
            if (got === exp) begin
                pass_cnt = pass_cnt + 1;
                $display("  [PASS] %0s : got=%0d exp=%0d", name, got, exp);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("  [FAIL] %0s : got=%0d exp=%0d  <-- MISMATCH", name, got, exp);
            end
        end
    endtask

    // ---------------------------------------------------------------- 激励
    // 按下按键 idx（0/1），保持 hold_ms 毫秒，然后释放
    // 注：模块内部以"ms 整数"计,所以这里 hold_ms 也用整数毫秒
    task press;
        input integer idx;        // 0 或 1
        input integer hold_ms;
        integer i;
        reg [1:0] pat;
        begin
            // 建立按下
            pat = 2'b11;
            pat[idx] = 1'b0;
            I_button = pat;
            // 保持：hold_ms 个"模块内毫秒"
            repeat ((CLK_FREQ_HZ/1000)*hold_ms + 8) @(posedge I_clk);
            // 释放
            I_button = 2'b11;
            repeat ((CLK_FREQ_HZ/1000)*TB_DEBOUNCE_MS + 16) @(posedge I_clk);
        end
    endtask

    // ---------------------------------------------------------------- 主流程
    initial begin
        $display("");
        $display("========================================================");
        $display(" tb_key_mode_ctrl -- key_mode_ctrl functional self-check");
        $display("   CLK_FREQ_HZ  = %0d", CLK_FREQ_HZ);
        $display("   DEBOUNCE     = %0d ms  (%0d cycles)", TB_DEBOUNCE_MS, DEB_CYC);
        $display("   LONGPRESS    = %0d ms  (%0d cycles)", TB_LONGPRESS_MS, LP_CYC);
        $display("========================================================");

        // ---------------- 复位 ----------------
        $display("");
        $display("[T0] reset behaviour");
        I_rst_n = 1'b0;
        repeat (20) @(posedge I_clk);
        check_int("T0 O_mode reset value",   O_mode,   3'b000);
        check_int("T0 O_btn_ae reset value", O_btn_ae, 2'b11);
        I_rst_n = 1'b1;
        repeat (20) @(posedge I_clk);

        // ---------------- T1: 短按 KEY0 → 模式 0→1 ----------------
        $display("");
        $display("[T1] short press KEY0 -> O_mode 0 -> 1 (cycle)");
        press(0, TB_LONGPRESS_MS - 1);
        check_int("T1 O_mode should be 1", O_mode, 3'd1);
        check_int("T1 AE gate should return 1",    O_btn_ae[0], 1'b1);

        // ---------------- T2: 继续短按 KEY0 → 1→2→3→4→0 完整循环（P4 共 5 模式）----------------
        $display("");
        $display("[T2] keep short pressing KEY0 -> 2 -> 3 -> 4 -> 0 (full 5-mode cycle)");
        press(0, TB_LONGPRESS_MS - 1);
        check_int("T2 O_mode should be 2 (binary)", O_mode, 3'd2);
        press(0, TB_LONGPRESS_MS - 1);
        check_int("T2 O_mode should be 3 (invert)", O_mode, 3'd3);
        press(0, TB_LONGPRESS_MS - 1);
        check_int("T2 O_mode should be 4 (cartoon)", O_mode, 3'd4);
        press(0, TB_LONGPRESS_MS - 1);
        check_int("T2 O_mode should wrap back to 0", O_mode, 3'd0);

        // ---------------- T3: 长按 KEY0 → 不切模式，且 AE 可见 ----------------
        $display("");
        $display("[T3] long press KEY0 -> O_mode must NOT change, AE gate opens");
        begin : t3
            integer i;
            reg [1:0] pat;
            reg [1:0] before;
            before = O_mode;
            // 按下
            pat = 2'b11; pat[0] = 1'b0;
            I_button = pat;
            // 等到超过长按阈值 + 去抖
            repeat ((CLK_FREQ_HZ/1000)*(TB_LONGPRESS_MS+TB_DEBOUNCE_MS) + 32) @(posedge I_clk);
            check_int("T3 during long press AE gate should be 0", O_btn_ae[0], 1'b0);
            // 再保持一会儿后释放
            repeat ((CLK_FREQ_HZ/1000)*TB_DEBOUNCE_MS + 16) @(posedge I_clk);
            I_button = 2'b11;
            repeat ((CLK_FREQ_HZ/1000)*TB_DEBOUNCE_MS + 16) @(posedge I_clk);
            check_int("T3 after long press O_mode unchanged", O_mode, before);
        end
        check_int("T3 after release AE gate should return 1",     O_btn_ae[0], 1'b1);

        // ---------------- T4: 短按 KEY1 → **不改模式**（改编后语义）----------------
        $display("");
        $display("[T4] short press KEY1 -> O_mode must NOT change (KEY1 is AE-only now)");
        begin : t4
            reg [1:0] before;
            before = O_mode;
            press(1, TB_LONGPRESS_MS - 1);
            check_int("T4 O_mode unchanged by KEY1 short press", O_mode, before);
            check_int("T4 AE gate (key1) should return 1", O_btn_ae[1], 1'b1);
        end

        // ---------------- T5: 长按 KEY1 → 不切模式，AE 可见 ----------------
        $display("");
        $display("[T5] long press KEY1 -> O_mode must NOT change, AE gate opens");
        begin : t5
            reg [1:0] pat;
            reg [1:0] before;
            before = O_mode;
            pat = 2'b11; pat[1] = 1'b0;
            I_button = pat;
            repeat ((CLK_FREQ_HZ/1000)*(TB_LONGPRESS_MS+TB_DEBOUNCE_MS) + 32) @(posedge I_clk);
            check_int("T5 during long press AE gate (key1) should be 0", O_btn_ae[1], 1'b0);
            repeat ((CLK_FREQ_HZ/1000)*TB_DEBOUNCE_MS + 16) @(posedge I_clk);
            I_button = 2'b11;
            repeat ((CLK_FREQ_HZ/1000)*TB_DEBOUNCE_MS + 16) @(posedge I_clk);
            check_int("T5 after long press O_mode unchanged", O_mode, before);
        end

        // ---------------- T6: 抖动脉冲不应被当作短按 ----------------
        $display("");
        $display("[T6] glitches shorter than debounce must not toggle mode");
        begin : t6
            integer k;
            reg [1:0] before;
            before = O_mode;
            for (k = 0; k < 5; k = k + 1) begin
                I_button = 2'b10;                       // 压 key0
                repeat (DEB_CYC/4) @(posedge I_clk);    // 不够去抖时间
                I_button = 2'b11;                       // 放开
                repeat (DEB_CYC/4) @(posedge I_clk);
            end
            repeat ((CLK_FREQ_HZ/1000)*TB_DEBOUNCE_MS + 16) @(posedge I_clk);
            check_int("T6 mode should be unchanged after glitches", O_mode, before);
        end

        // ---------------- T7: ★ P6 新增 —— 短按 KEY2 产生 O_auto_tog 单拍脉冲 ----------------
        //   语义：KEY2（I_button[1]）**短按释放**时给出一个单拍脉冲（AE 自动/手动切换）。
        //   ⚠ 与长按互斥：长按 KEY2 是"调 AG"，**不得**产生切换脉冲，
        //     否则演示时想微调增益会把自动模式切掉，很难排查。
        $display("");
        $display("[T7] P6: short press KEY2 -> O_auto_tog single pulse; long press -> none");
        begin : t7
            integer k, pulses, lp_pulses;
            // ---- 短按 KEY2 ----
            pulses = 0;
            I_button = 2'b01;                              // 压 key1（I_button[1]）
            repeat ((CLK_FREQ_HZ/1000)*TB_DEBOUNCE_MS + 16) @(posedge I_clk);
            I_button = 2'b11;                              // 放开（未达长按阈值）
            for (k = 0; k < 400; k = k + 1) begin
                @(posedge I_clk);
                if (O_auto_tog) pulses = pulses + 1;
            end
            check_int("T7a short press KEY2 -> exactly 1 toggle pulse", pulses, 1);
            // ---- 再短按一次，应当**又**给一个脉冲（每次短按都切换）----
            pulses = 0;
            I_button = 2'b01;
            repeat ((CLK_FREQ_HZ/1000)*TB_DEBOUNCE_MS + 16) @(posedge I_clk);
            I_button = 2'b11;
            for (k = 0; k < 400; k = k + 1) begin
                @(posedge I_clk);
                if (O_auto_tog) pulses = pulses + 1;
            end
            check_int("T7b second short press -> exactly 1 more pulse", pulses, 1);
            // ---- 长按 KEY2：不得产生切换脉冲 ----
            //   ⚠ 等长按判定用的周期数要**按标称值算**（LP_CYC），不要写死几千拍 ——
            //     写死会把整份仿真推过 50 ms 超时保护（本 TB 是缩短参数跑的快仿）。
            lp_pulses = 0;
            I_button = 2'b01;
            repeat (LP_CYC + 40) @(posedge I_clk);
            I_button = 2'b11;
            for (k = 0; k < 400; k = k + 1) begin
                @(posedge I_clk);
                if (O_auto_tog) lp_pulses = lp_pulses + 1;
            end
            check_int("T7c long press KEY2 -> NO toggle pulse", lp_pulses, 0);
        end

        // ---------------- 汇总 ----------------
        $display("");
        $display("========================================================");
        $display(" PASSED %0d checks, FAILED %0d checks", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display(" *** ALL TESTS PASSED ***");
        else
            $display(" *** THERE WERE %0d FAILURES ***", fail_cnt);
        $display("========================================================");
        $display("");
        $finish;
    end

    // 超时保护
    //   ⚠ P6 加了 T7（短按/长按 KEY2 的切换脉冲）之后，用例总时长变长，
    //     原来 50 ms 的上限会被顶到 ⇒ 放宽到 200 ms（这只是**仿真上限**，
    //     参数是缩短的，与真机 500 ms 长按无关）。
    initial begin
        #200_000_000;
        $display(" *** TIMEOUT -- simulation did not finish in expected time ***");
        $finish;
    end

endmodule
