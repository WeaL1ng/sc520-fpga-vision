// ============================================================================
//  tb_awb_rate3.v  ---  awb 吞吐三级对照（基线 / P1a-FIXED / P1a-UNFIXED）
//
//  与 tb_awb_rate.v 的关键区别：激励改成**真实突发形态**。
//
//  为什么必须这样激励：
//    awb 内部 signal_delay 的 rd_valid 在 h_cnt==DELAY_CYCLE-3（=51）拉高，
//    连发 IMG_WIDTH/4（=320）拍后拉低。所以 awb 的输出侧每行是
//    「320 拍连续突发 + 51 拍空档」，而不是均匀流。
//    若测试台按均匀流灌 data，就等效于把 FIFO 的写侧摊平，会低估溢出，
//    得出的"达标"结论是假象（这正是上一版 tb 的缺陷）。
//
//  判定：
//    drop_cnt = fifo_wr & fifo_full   -> IP 源码 soft_fifo L77 wr_en_s=(!full)&we
//                                        满时静默丢字，屏幕上就是撕裂。
//    cyc/out  = 稳态窗口拍数 / 输出字数
//
//  DUT 用 `ifdef 选择：默认 awb（P1a）；-Dref 选 awb_ref（基线，1 字/拍）；
//  -DD4UNFIXED 选仅回退 D4 的 P1a 版本。
// ============================================================================
`timescale 1ns/1ps

module tb_awb_rate3;

    localparam integer IMG_W   = 1280;
    localparam integer IMG_H   = 720;
    localparam integer W_GRP   = IMG_W / 4;        // 320 字/行
    localparam integer GAP     = 51;               // signal_delay 的行内空档
    localparam integer NLINES  = 60;
    localparam integer WIN_LO  = 4000;
    localparam integer WIN_HI  = 30000;

    reg clk = 0;
    reg rst_n = 0;
    always #1 clk = ~clk;

    reg         I_tlast = 0, I_tuser = 0, I_tvalid = 0;
    reg  [95:0] I_tdata = 96'd0;
    wire        O_tlast, O_tuser, O_tvalid;
    wire [95:0] O_tdata;

`ifdef D4UNFIXED
    awb #(.IMG_HEIGHT(IMG_H), .IMG_WIDTH(IMG_W)) dut (
`elsif ref
    awb_ref #(.IMG_HEIGHT(IMG_H), .IMG_WIDTH(IMG_W)) dut (
`else
    awb #(.IMG_HEIGHT(IMG_H), .IMG_WIDTH(IMG_W)) dut (
`endif
        .I_clk(clk), .I_rst_n(rst_n),
        .I_tlast(I_tlast), .I_tuser(I_tuser),
        .I_tdata(I_tdata), .I_tvalid(I_tvalid), .I_tready(),
        .O_tlast(O_tlast), .O_tuser(O_tuser),
        .O_tdata(O_tdata), .O_tvalid(O_tvalid), .O_tready(1'b1)
    );

    // 探针：只有 P1a（awb TDM 版）内部有 w155 FIFO；
    // 厂商原版（含恢复后的 lab4 awb.v）与 awb_ref 都是 8 并行乘法器直通，
    // 内部没有任何 FIFO，所以这些探针必须条件编译，否则 vlog 报 unresolved。
    // NOFIFO 由脚本对 ref / fixed 两个 DUT 定义。
`ifdef NOFIFO
    wire        fifo_wr   = 1'b0;
    wire        fifo_rd   = 1'b0;
    wire        fifo_full = 1'b0;
    wire [8:0]  fifo_used = 9'd0;
`else
    wire        fifo_wr   = dut.fifo_wr;
    wire        fifo_rd   = dut.fifo_rd;
    wire        fifo_full = dut.u_awb_fifo.full_flag;
    wire [8:0]  fifo_used = dut.u_awb_fifo.wrusedw;
`endif

    integer in_cnt = 0, out_cnt = 0, rd_cnt = 0, wr_cnt = 0, cyc = 0;
    integer drop_cnt = 0, cyc_first_drop = -1;
    integer peak_used = 0, last_used = 0;
    integer win_cyc = 0, win_out = 0, win_drop = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            cyc = cyc + 1;
            if (I_tvalid)  in_cnt  = in_cnt  + 1;
            if (O_tvalid)  out_cnt = out_cnt + 1;
            if (fifo_rd)   rd_cnt  = rd_cnt  + 1;
            if (fifo_wr)   wr_cnt  = wr_cnt  + 1;
            if (fifo_wr && fifo_full) begin
                drop_cnt = drop_cnt + 1;
                if (cyc_first_drop < 0) cyc_first_drop = cyc;
            end
            if (fifo_used > peak_used) peak_used = fifo_used;
            last_used = fifo_used;
            if (cyc > WIN_LO && cyc <= WIN_HI) begin
                win_cyc = win_cyc + 1;
                if (O_tvalid)             win_out  = win_out  + 1;
                if (fifo_wr && fifo_full) win_drop = win_drop + 1;
            end
        end
    end

    integer i, ln;
    initial begin
        $display("");
        $display("============================================================");
`ifdef D4UNFIXED
        $display(" tb_awb_rate3 : DUT = awb (P1a, D4 UNFIXED)");
`elsif ref
        $display(" tb_awb_rate3 : DUT = awb_ref (BASELINE, 8 parallel mult)");
`else
        $display(" tb_awb_rate3 : DUT = awb (lab4 hdl_source, restored vendor baseline)");
`endif
        $display("   burst stimulus: %0d words back-to-back + %0d idle, x%0d lines",
                 W_GRP, GAP, NLINES);
        $display("============================================================");

        rst_n = 0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        I_tuser = 1'b1; @(posedge clk); I_tuser = 1'b0;
        for (ln = 0; ln < NLINES; ln = ln + 1) begin
            // ---- 320 字连续突发（模拟 signal_delay 的 rd_valid 窗口）----
            for (i = 0; i < W_GRP; i = i + 1) begin
                I_tdata  = {24'h808080, 24'h606060, 24'h404040, 24'h202020};
                I_tvalid = 1'b1;
                I_tlast  = (i == W_GRP-1);
                @(posedge clk);
            end
            // ---- 行内空档 ----
            I_tvalid = 1'b0; I_tlast = 1'b0;
            repeat (GAP) @(posedge clk);
        end
        I_tvalid = 1'b0; I_tlast = 1'b0;
        repeat (3000) @(posedge clk);

        $display("  ---- totals ----");
        $display("  in_cnt   (I_tvalid)      = %0d", in_cnt);
        $display("  wr_cnt   (fifo_wr)       = %0d", wr_cnt);
        $display("  rd_cnt   (fifo_rd)       = %0d", rd_cnt);
        $display("  out_cnt  (O_tvalid)      = %0d", out_cnt);
        $display("  drop_cnt (wr & full)     = %0d  %s", drop_cnt,
                 (drop_cnt == 0) ? "<-- NO word dropped" : "<-- WORDS DROPPED");
        if (cyc_first_drop > 0)
            $display("  first drop at cycle      = %0d", cyc_first_drop);
        $display("  FIFO peak occupancy      = %0d / 512", peak_used);
        $display("  FIFO final occupancy     = %0d", last_used);
        $display("");
        $display("  ---- steady window (cycles %0d..%0d) ----", WIN_LO+1, WIN_HI);
        $display("  window cycles            = %0d", win_cyc);
        $display("  window out words         = %0d", win_out);
        $display("  window drops             = %0d", win_drop);
        $display("");
        if (win_out == 0) begin
            $display("  [FAIL] no output in steady window");
        end else begin
            $display("  cycles per OUTPUT word   = %0d.%02d   (budget 4.30)",
                     win_cyc / win_out, ((win_cyc * 100) / win_out) % 100);
            if (win_cyc * 100 <= win_out * 430)
                $display("  [PASS] rate within budget");
            else
                $display("  [FAIL] rate exceeds budget");
        end
        if (drop_cnt == 0)
            $display("  [PASS] FIFO never overflowed -> no word lost");
        else
            $display("  [FAIL] FIFO overflowed -> %0d input words lost", drop_cnt);
        $display("============================================================");
        $finish;
    end

    initial begin
        #80000000;
        $display("  [FAIL] timeout (in=%0d out=%0d drop=%0d)", in_cnt, out_cnt, drop_cnt);
        $finish;
    end

endmodule
