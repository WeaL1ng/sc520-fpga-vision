// ============================================================================
//  tb_awb_rate.v  ---  awb 稳态吞吐 / FIFO 溢出 判定台
//
//  目的：判定 awb（ISP 域）能否无丢字地跟上连续输入流。
//
//  机理（来自 RTL 与 IP 源码，不是猜测）：
//    * ISP 域 f_clk = MIPI_RX_BYTE_CLK/2 = 59.4 MHz，1 个 96bit 字 = 4 像素
//      720p60 = 55.296 Mpix/s  =>  13.824 M 字/s
//      => 每个输入字可用 59.4e6/13.824e6 = **4.30 拍**
//    * awb 内部 w155_d512_fifo 深度 512，
//      soft_fifo_al_f58e8b3e1f3d.v L77 : wr_en_s = (!full_flag) & we
//      => FIFO 满时写入被**静默丢弃**（无溢出标志、无报错）。
//      丢字在屏幕上的表现就是撕裂 / 只有一半画面在动。
//
//  判定量（每一条都是可直接观测的硬件信号）：
//    drop_cnt  = fifo_wr & fifo_full        <- 被丢弃的输入字（必须为 0）
//    cyc/out   = 稳态窗口拍数 / 输出字数    <- 必须 <= 4.30
//    occupancy = FIFO 稳态占用              <- 不接近 512 才安全
//
//  ⚠ IMG_WIDTH 必须保持 1280：awb 内 signal_delay 的 rd_valid 只在
//    h_cnt ∈ [DELAY_CYCLE-3, IMG_WIDTH/4-1] = [51,319] 有效。
//    取小值则 h_cnt 到不了 51，永远没有输出（此坑已踩过）。
//
//  编译时必须用 divider_beh.v（50 拍延迟、1 结果/拍的行为模型）
//  代替 divider_gate.v：门级网表 64k 行会把仿真拖到超时。
// ============================================================================
`timescale 1ns/1ps

module tb_awb_rate;

    localparam integer IMG_W  = 1280;
    localparam integer IMG_H  = 720;
    localparam integer W_GRP  = IMG_W / 4;        // 320 字/行
    localparam integer NLINES = 200;
    localparam integer NWORD  = W_GRP * NLINES;   // 64000 字
    localparam integer WIN_LO = 3000;             // 稳态窗口起点
    localparam integer WIN_HI = 20000;            // 稳态窗口终点

    reg clk = 0;
    reg rst_n = 0;
    always #1 clk = ~clk;                          // 只跑逻辑，周期取 2ns

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

    // ---- 观测信号 -------------------------------------------------------
    wire        fifo_wr   = dut.fifo_wr;
    wire        fifo_rd   = dut.fifo_rd;
    wire        fifo_full = dut.u_awb_fifo.full_flag;
    wire [8:0]  fifo_used = dut.u_awb_fifo.wrusedw;

    integer in_cnt = 0, out_cnt = 0, rd_cnt = 0, wr_cnt = 0, cyc = 0;
    integer drop_cnt = 0, cyc_at_first_drop = -1;
    integer peak_used = 0, last_used = 0;
    integer win_cyc = 0, win_out = 0, win_drop = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            cyc = cyc + 1;
            if (I_tvalid)  in_cnt  = in_cnt  + 1;
            if (O_tvalid)  out_cnt = out_cnt + 1;
            if (fifo_rd)   rd_cnt  = rd_cnt  + 1;
            if (fifo_wr)   wr_cnt  = wr_cnt  + 1;

            // 溢出观测：写请求被 full_flag 挡掉 == 丢字
            if (fifo_wr && fifo_full) begin
                drop_cnt = drop_cnt + 1;
                if (cyc_at_first_drop < 0) cyc_at_first_drop = cyc;
            end
            if (fifo_used > peak_used) peak_used = fifo_used;
            last_used = fifo_used;

            if (cyc > WIN_LO && cyc <= WIN_HI) begin
                win_cyc = win_cyc + 1;
                if (O_tvalid)              win_out  = win_out  + 1;
                if (fifo_wr && fifo_full)  win_drop = win_drop + 1;
            end
        end
    end

    integer i;
    initial begin
        $display("");
        $display("============================================================");
        $display(" tb_awb_rate : AWB steady-state rate & FIFO overflow");
        $display("   geometry %0dx%0d  %0d words/line  %0d lines  (%0d words)",
                 IMG_W, IMG_H, W_GRP, NLINES, NWORD);
        $display("============================================================");

        rst_n = 0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        // 零间隙连续灌流（MIPI 连续输出时就是这个形态），行末拉 tlast
        I_tuser = 1'b1; @(posedge clk); I_tuser = 1'b0;
        for (i = 0; i < NWORD; i = i + 1) begin
            I_tdata  = {24'h808080, 24'h606060, 24'h404040, 24'h202020};
            I_tvalid = 1'b1;
            I_tlast  = ((i % W_GRP) == (W_GRP-1));
            @(posedge clk);
        end
        I_tvalid = 1'b0; I_tlast = 1'b0;
        repeat (2000) @(posedge clk);      // 排空

        $display("  ---- totals ----");
        $display("  in_cnt   (I_tvalid)      = %0d", in_cnt);
        $display("  wr_cnt   (fifo_wr)       = %0d", wr_cnt);
        $display("  rd_cnt   (fifo_rd)       = %0d", rd_cnt);
        $display("  out_cnt  (O_tvalid)      = %0d", out_cnt);
        $display("  drop_cnt (wr & full)     = %0d   %s",
                 drop_cnt, (drop_cnt == 0) ? "<-- no word dropped" : "<-- WORDS DROPPED");
        if (cyc_at_first_drop > 0)
            $display("  first drop at cycle      = %0d", cyc_at_first_drop);
        $display("  FIFO peak occupancy      = %0d / 512", peak_used);
        $display("  FIFO final occupancy     = %0d", last_used);
        $display("");
        $display("  ---- steady window (cycles %0d..%0d) ----", WIN_LO+1, WIN_HI);
        $display("  window cycles            = %0d", win_cyc);
        $display("  window out words         = %0d", win_out);
        $display("  window drops             = %0d", win_drop);
        $display("");
        $display("  ---- verdict ----");
        if (win_out == 0) begin
            $display("  [FAIL] no output in steady window");
        end else begin
            $display("  cycles per OUTPUT word   = %0d.%02d   (budget 4.30)",
                     win_cyc / win_out, ((win_cyc * 100) / win_out) % 100);
            if (win_cyc * 100 <= win_out * 430)
                $display("  [PASS] rate <= 4.30 cyc/word -> keeps up with the input");
            else
                $display("  [FAIL] rate >  4.30 cyc/word -> cannot keep up");
        end
        if (drop_cnt == 0)
            $display("  [PASS] FIFO never overflowed -> no word lost");
        else
            $display("  [FAIL] FIFO overflowed %0d times -> %0d input words lost",
                     drop_cnt / 1, drop_cnt);
        $display("============================================================");
        $finish;
    end

    initial begin
        #40000000;
        $display("  [FAIL] timeout (in=%0d out=%0d drop=%0d)", in_cnt, out_cnt, drop_cnt);
        $finish;
    end

endmodule
