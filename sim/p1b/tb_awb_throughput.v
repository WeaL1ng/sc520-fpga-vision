// ============================================================================
//  tb_awb_throughput.v
//  测 awb 的**稳态输出率**，判断是否满足 720p60 的吞吐要求
//
//  判据（纯时序，不涉算法语义）
//     ISP 域时钟 f_clk = MIPI_RX_BYTE_CLK / 2
//     720p60 需要 55.296e6/4 = 13.824 M 字/s
//     => 每个输出字最多可用 f_clk / 13.824e6 = 4.30 拍
//     本 TB 用真实几何（1280x720，320 字/行），连续灌多行，
//     统计稳态区间的"每输出字消耗拍数"。
//
//  ⚠ 必须用真实 IMG_WIDTH=1280：
//     awb 内部 signal_delay 的 rd_valid 只在 h_cnt∈[DELAY_CYCLE-3, W/4-1]
//     内有效。若把 IMG_WIDTH 设成小值，h_cnt 到不了 DELAY_CYCLE-3=51，
//     就永远没有输出（这个坑踩过）。
// ============================================================================
`timescale 1ns/1ps

module tb_awb_throughput;

    localparam integer IMG_W  = 1280;
    localparam integer IMG_H  = 720;
    localparam integer W_GRP  = IMG_W / 4;        // 320 字/行
    localparam integer NLINES = 60;
    localparam integer NWORD  = W_GRP * NLINES;

    reg clk = 0;
    reg rst_n = 0;
    always #1 clk = ~clk;                          // 周期 2ns，只跑逻辑

    reg         I_tlast = 0, I_tuser = 0, I_tvalid = 0;
    reg  [95:0] I_tdata = 96'd0;
    wire        O_tlast, O_tuser, O_tvalid;

    awb #(.IMG_HEIGHT(IMG_H), .IMG_WIDTH(IMG_W)) dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_tlast(I_tlast), .I_tuser(I_tuser),
        .I_tdata(I_tdata), .I_tvalid(I_tvalid), .I_tready(),
        .O_tlast(O_tlast), .O_tuser(O_tuser),
        .O_tdata(), .O_tvalid(O_tvalid), .O_tready(1'b1)
    );

    integer in_cnt = 0, out_cnt = 0, rd_cnt = 0, wr_cnt = 0, cyc = 0;
    integer win_cyc = 0, win_in = 0, win_out = 0, win_rd = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            cyc = cyc + 1;
            if (I_tvalid)   in_cnt  = in_cnt  + 1;
            if (O_tvalid)   out_cnt = out_cnt + 1;
            if (dut.fifo_rd) rd_cnt = rd_cnt + 1;
            if (dut.fifo_wr) wr_cnt = wr_cnt + 1;
            // 稳态窗口：跳过前 2000 拍（填充+帧内延迟），取接下来 8000 拍
            if (cyc > 2000 && cyc <= 10000) begin
                win_cyc = win_cyc + 1;
                if (I_tvalid)    win_in  = win_in  + 1;
                if (O_tvalid)    win_out = win_out + 1;
                if (dut.fifo_rd) win_rd  = win_rd  + 1;
            end
        end
    end

    integer i;
    initial begin
        $display("============================================================");
        $display(" tb_awb_throughput : steady-state output rate");
        $display("   geometry %0dx%0d  %0d words/line  %0d lines",
                 IMG_W, IMG_H, W_GRP, NLINES);
        $display("============================================================");

        rst_n = 0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        // 连续灌（零间隙），行末拉 tlast
        I_tuser = 1'b1; @(posedge clk); I_tuser = 1'b0;
        for (i = 0; i < NWORD; i = i + 1) begin
            I_tdata  = {24'h808080, 24'h404040, 24'h202020, 24'h101010};
            I_tvalid = 1'b1;
            I_tlast  = ((i % W_GRP) == (W_GRP-1));
            @(posedge clk);
        end
        I_tvalid = 1'b0; I_tlast = 1'b0;
        repeat (500) @(posedge clk);

        $display("  ---- totals ----");
        $display("  in_cnt  (I_tvalid)  = %0d", in_cnt);
        $display("  wr_cnt  (fifo_wr)   = %0d", wr_cnt);
        $display("  rd_cnt  (fifo_rd)   = %0d", rd_cnt);
        $display("  out_cnt (O_tvalid)  = %0d", out_cnt);
        $display("");
        $display("  ---- steady window (cycles 2001..10000) ----");
        $display("  window cycles       = %0d", win_cyc);
        $display("  window in  words    = %0d", win_in);
        $display("  window out words    = %0d", win_out);
        $display("  window fifo reads   = %0d", win_rd);
        $display("");
        $display("  ---- verdict ----");
        if (win_out == 0) begin
            $display("  [FAIL] no output in the steady window");
        end else begin
            $display("  cycles per OUTPUT word = %0d.%02d   (budget 4.30)",
                     win_cyc / win_out, ((win_cyc * 100) / win_out) % 100);
            if (win_cyc * 100 <= win_out * 430)
                $display("  [PASS] <= 4.30 cycles/word -> AWB keeps up, FIFO will not overflow");
            else
                $display("  [FAIL] > 4.30 cycles/word -> FIFO overflows, words ARE dropped");
        end
        $display("============================================================");
        $finish;
    end

    initial begin
        #20000000;
        $display("  [FAIL] timeout (in=%0d out=%0d)", in_cnt, out_cnt);
        $finish;
    end

endmodule
