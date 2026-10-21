// ============================================================================
//  tb_awb_probe.v  --  诊断 awb 内部状态（为什么没有输出）
// ============================================================================
`timescale 1ns/1ps

module tb_awb_probe;

    localparam integer NWORD = 512;

    reg clk = 0;
    reg rst_n = 0;
    always #1 clk = ~clk;

    reg         I_tlast = 0, I_tuser = 0, I_tvalid = 0;
    reg  [95:0] I_tdata = 96'd0;
    wire        O_tlast, O_tuser, O_tvalid;

    awb #(.IMG_HEIGHT(720), .IMG_WIDTH(1280)) dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_tlast(I_tlast), .I_tuser(I_tuser),
        .I_tdata(I_tdata), .I_tvalid(I_tvalid), .I_tready(),
        .O_tlast(O_tlast), .O_tuser(O_tuser),
        .O_tdata(), .O_tvalid(O_tvalid), .O_tready(1'b1)
    );

    integer in_cnt = 0, out_cnt = 0, wr_cnt = 0;
    integer busy_cnt = 0, rd_cnt = 0, empty_cnt = 0;
    integer ph3_cnt = 0, outv_w_cnt = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (I_tvalid) in_cnt = in_cnt + 1;
            if (O_tvalid) out_cnt = out_cnt + 1;
            if (dut.fifo_wr) wr_cnt = wr_cnt + 1;
            if (dut.fifo_rd) rd_cnt = rd_cnt + 1;
            if (dut.mul_busy) busy_cnt = busy_cnt + 1;
            if (dut.fifo_empty) empty_cnt = empty_cnt + 1;
            if (dut.mul_ph == 2'd3) ph3_cnt = ph3_cnt + 1;
            if (dut.out_valid_w) outv_w_cnt = outv_w_cnt + 1;
        end
    end

    integer i;
    initial begin
        $display("============================================================");
        $display(" tb_awb_probe : diagnose awb internal state");
        $display("============================================================");

        rst_n = 0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        I_tuser = 1'b1; @(posedge clk); I_tuser = 1'b0;
        for (i = 0; i < NWORD; i = i + 1) begin
            I_tdata  = {24'h808080, 24'h404040, 24'h202020, 24'h101010};
            I_tvalid = 1'b1;
            I_tlast  = (i == NWORD-1);
            @(posedge clk);
        end
        I_tvalid = 1'b0; I_tlast = 1'b0;
        repeat (200) @(posedge clk);

        $display("  ---- counters ----");
        $display("  in_cnt       (I_tvalid)   = %0d", in_cnt);
        $display("  wr_cnt       (fifo_wr)    = %0d", wr_cnt);
        $display("  rd_cnt       (fifo_rd)    = %0d", rd_cnt);
        $display("  busy_cnt     (mul_busy)   = %0d", busy_cnt);
        $display("  ph3_cnt      (mul_ph==3)  = %0d", ph3_cnt);
        $display("  outv_w_cnt   (out_valid_w)= %0d", outv_w_cnt);
        $display("  out_cnt      (O_tvalid)   = %0d", out_cnt);
        $display("  empty_cnt    (fifo_empty) = %0d", empty_cnt);
        $display("");
        $display("  ---- frozen end state ----");
        $display("  mul_busy=%b mul_ph=%0d mul_ph_d1=%0d fifo_empty=%b",
                 dut.mul_busy, dut.mul_ph, dut.mul_ph_d1, dut.fifo_empty);
        $display("  valid_d0=%b valid_d1=%b I_tvalid_r1=%b",
                 dut.valid_d0, dut.valid_d1, dut.I_tvalid_r1);
        $display("  out_valid_w=%b out_valid_d1=%b O_tvalid=%b",
                 dut.out_valid_w, dut.out_valid_d1, O_tvalid);
        $display("============================================================");
        $display("  DIAGNOSIS:");
        if (wr_cnt == 0)
            $display("    [X] FIFO never written -> signal_delay/valid path broken");
        else if (rd_cnt == 0)
            $display("    [X] FIFO written but never read -> fifo_rd never asserted");
        else if (outv_w_cnt == 0)
            $display("    [X] FIFO read but out_valid_w never pulsed -> mul_ph_d1/mul_busy issue");
        else if (out_cnt == 0)
            $display("    [X] out_valid_w pulsed %0d but O_tvalid never high -> output reg path", outv_w_cnt);
        else
            $display("    [OK] pipeline produced %0d words from %0d in (rd=%0d)", out_cnt, in_cnt, rd_cnt);
        $display("============================================================");
        $finish;
    end

    initial begin
        #2000000;
        $display("  [FAIL] timeout");
        $finish;
    end

endmodule
