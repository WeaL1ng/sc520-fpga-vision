// ============================================================================
//  tb_key_ctrl.v  --  lab_topic2_basic / key_ctrl.v 的自检 TB
//
//  被测：key_ctrl（双键两级同步 + 去抖 + 长短按判别）
//
//  为把仿真时间压到秒级，参数按比例缩小（保持**周期数**关系不变）：
//     CLK_FREQ_HZ  = 100_000   (10us 周期)
//     DEBOUNCE_MS  = 1         -> DEBOUNCE_CYC  = 100   拍
//     LONGPRESS_MS = 2         -> LONGPRESS_CYC = 200   拍
//  真实参数为 23810000 / 20 / 500 -> 476200 / 11905000 拍，比例关系一致。
//
//  验证内容
//    T0  复位：O_short/O_long = 0
//    T1  释放态：长时间不动 -> 无任何输出
//    T2  短按：按下 < LONGPRESS 后释放 -> O_short 恰好 1 拍脉冲，O_long 全程 0
//    T3  长按：按住 >= LONGPRESS -> O_long 拉高；释放 -> O_long 归 0 且**无** O_short
//    T4  毛刺抑制：< DEBOUNCE_CYC 的窄脉冲 -> 完全无输出
//    T5  双键独立：KEY1 短按不影响 KEY2 的输出
//    T6  连续两次短按 -> 恰好 2 个脉冲
//
//  运行：vlog key_ctrl.v tb_key_ctrl.v ; vsim -batch -lib work tb_key_ctrl -do "run -all; quit -f"
// ============================================================================
`timescale 1us/1ns

module tb_key_ctrl;

    localparam integer CLK_HZ  = 100000;
    localparam integer DEB_MS  = 1;
    localparam integer LP_MS   = 2;
    localparam integer DEB_CYC = (CLK_HZ/1000)*DEB_MS;    // 100
    localparam integer LP_CYC  = (CLK_HZ/1000)*LP_MS;     // 200
    localparam real    TP      = 1000000.0/CLK_HZ;        // 10 us

    reg         clk   = 0;
    reg         rst_n = 0;
    reg  [1:0]  I_button = 2'b11;      // 低有效：1=释放 0=按下

    wire [1:0]  O_short, O_long;

    key_ctrl #(
        .CLK_FREQ_HZ (CLK_HZ),
        .DEBOUNCE_MS (DEB_MS),
        .LONGPRESS_MS(LP_MS)
    ) dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_button(I_button),
        .O_short(O_short), .O_long(O_long)
    );

    always #(TP/2.0) clk = ~clk;

    integer errors = 0, checks = 0;

    // ---- 输出侧统计计数器 ----
    integer sh0, sh1, lg0, lg1;
    reg     watch = 1'b0;

    always @(posedge clk) begin
        if (watch) begin
            if (O_short[0]) sh0 = sh0 + 1;
            if (O_short[1]) sh1 = sh1 + 1;
            if (O_long [0]) lg0 = lg0 + 1;
            if (O_long [1]) lg1 = lg1 + 1;
        end
    end

    task clear_cnt; begin sh0=0; sh1=0; lg0=0; lg1=0; end endtask

    task assert_chk;
        input [8*56:1] name;
        input          cond;
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("  [FAIL] %0s", name);
            end else
                $display("  [ ok ] %0s", name);
        end
    endtask

    task clks;
        input integer n;
        integer j;
        begin for (j=0;j<n;j=j+1) @(posedge clk); end
    endtask

    integer rep_i;

    initial begin
        $display("============================================================");
        $display(" tb_key_ctrl  --  自检开始");
        $display("   参数(仿真)：CLK=%0d Hz  DEBOUNCE=%0d 拍  LONGPRESS=%0d 拍",
                 CLK_HZ, DEB_CYC, LP_CYC);
        $display("   真实参数  ：23.81 MHz  476200 拍(=20ms)   11905000 拍(=500ms)");
        $display("============================================================");

        // ---------- T0 复位 ----------
        rst_n = 0;
        clks(5);
        assert_chk("T0 reset: O_short==0", O_short === 2'b00);
        assert_chk("T0 reset: O_long==0", O_long  === 2'b00);
        rst_n = 1;
        clks(5);

        // ---------- T1 释放态 ----------
        clear_cnt; watch = 1'b1;
        I_button = 2'b11;
        clks(DEB_CYC*3);
        watch = 1'b0;
        assert_chk("T1 released: no output at all", (sh0==0)&&(sh1==0)&&(lg0==0)&&(lg1==0));

        // ---------- T2 短按 KEY1 ----------
        // 按下 3/4 长按阈值（< LONGPRESS），再释放
        clear_cnt; watch = 1'b1;
        I_button[0] = 1'b0;                 // KEY1 按下
        clks(LP_CYC*3/4);                   // 150 拍 < 200
        assert_chk("T2 short press: O_long[0] stays 0", O_long[0] === 1'b0);
        I_button[0] = 1'b1;                 // 释放
        clks(DEB_CYC*3);
        watch = 1'b0;
        assert_chk("T2 short press: O_short[0] == exactly 1 cycle", sh0 === 1);
        assert_chk("T2 short press: O_short[1] == 0", sh1 === 0);
        assert_chk("T2 short press: O_long[0] == 0 always", lg0 === 0);

        // ---------- T3 长按 KEY1 ----------
        clear_cnt; watch = 1'b1;
        I_button[0] = 1'b0;                 // 按下
        clks(LP_CYC + DEB_CYC*2);           // 超过长按阈值
        assert_chk("T3 long press: O_long[0] is high", O_long[0] === 1'b1);
        I_button[0] = 1'b1;                 // 释放
        clks(DEB_CYC*3);
        watch = 1'b0;
        assert_chk("T3 release: O_long[0] back to 0", O_long[0] === 1'b0);
        assert_chk("T3 long-press release: NO O_short[0]", sh0 === 0);
        assert_chk("T3 long press: O_long[0] had high cycles", lg0 > 0);

        // ---------- T4 毛刺抑制 ----------
        clear_cnt; watch = 1'b1;
        I_button[0] = 1'b0;                 // 极窄按下
        clks(6);                            // 6 拍 << DEB_CYC(100)
        I_button[0] = 1'b1;
        clks(DEB_CYC*3);
        watch = 1'b0;
        assert_chk("T4 glitch<debounce: no O_short", sh0 === 0);
        assert_chk("T4 glitch: no O_long",             lg0 === 0);

        // ---------- T5 双键独立 ----------
        clear_cnt; watch = 1'b1;
        // 只动 KEY1
        I_button[0] = 1'b0; clks(LP_CYC*3/4); I_button[0] = 1'b1;
        clks(DEB_CYC*3);
        watch = 1'b0;
        assert_chk("T5 KEY1 short press -> sh0==1", sh0 === 1);
        assert_chk("T5 KEY1 press does NOT affect KEY2", (sh1===0)&&(lg1===0));

        // KEY2 长按，KEY1 不动
        clear_cnt; watch = 1'b1;
        I_button[1] = 1'b0; clks(LP_CYC + DEB_CYC*2); I_button[1] = 1'b1;
        clks(DEB_CYC*3);
        watch = 1'b0;
        assert_chk("T5 KEY2 long press -> lg1>0 and sh1==0", (lg1>0)&&(sh1===0));
        assert_chk("T5 KEY2 press does NOT affect KEY1", (lg0===0)&&(sh0===0));

        // ---------- T6 连续两次短按 ----------
        clear_cnt; watch = 1'b1;
        for (rep_i=0; rep_i<2; rep_i=rep_i+1) begin
            I_button[0] = 1'b0; clks(LP_CYC*3/4);
            I_button[0] = 1'b1; clks(DEB_CYC*3);
        end
        watch = 1'b0;
        assert_chk("T6 two short presses -> exactly 2 pulses", sh0 === 2);

        // ---------- T7 按下但不释放（一直按住）----------
        clear_cnt; watch = 1'b1;
        I_button[0] = 1'b0;
        clks(LP_CYC*3);                     // 长时间按住
        watch = 1'b0;
        assert_chk("T7 hold forever -> O_long[0]=1 and no O_short", (O_long[0]===1'b1)&&(sh0===0));
        I_button[0] = 1'b1;

        // ---------- 汇总 ----------
        $display("============================================================");
        if (errors == 0)
            $display(" 结果：**全部通过**   checks=%0d  errors=0", checks);
        else
            $display(" 结果：**失败**       checks=%0d  errors=%0d", checks, errors);
        $display("============================================================");
        $finish;
    end

    initial begin
        #20000000;   // 20 s 仿真时间上限
        $display("  [FAIL] 仿真超时");
        $finish;
    end

endmodule
