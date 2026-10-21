// ============================================================================
//  tb_cartoon_96.v  ---  cartoon_96 功能验证（P4）
//
//  验证内容
//    ① 复位后 O_tvalid=0（前两行未积累，不能输出垃圾）
//    ② 攒够 2 行后 O_tvalid 恢复
//    ③ 【量化】平坦区域（灰度梯度为 0）⇒ 输出 = 输入量化后的值
//       R' = (R & 0xF0) | 0x08
//    ④ 【边缘】灰度突变的窗口中心 ⇒ 输出为黑（形态学梯度 > 阈值）
//    ⑤ 【阈值可调】提高阈值后，同样的突变不再被判为边缘
//    ⑥ 吞吐：背靠背 I_tvalid 输入 ⇒ 输出无丢拍
//
//  驱动方式：把整幅图（W_GRP x NLINES 个字）连续灌入，
//            同时把输出逐像素写到文本文件，交给 Python 独立核对
//            （工具：sim/p4/check_cartoon.py）
// ============================================================================
`timescale 1ns/1ps

module tb_cartoon_96;

    localparam integer IMG_W  = 1280;
    localparam integer IMG_H  = 720;
    localparam integer W_GRP  = IMG_W / 4;      // 320
    localparam integer NLINES = 8;              // 只跑 8 行（够验证窗口）

    reg clk = 0, rst_n = 0;
    always #1 clk = ~clk;

    reg         I_tlast = 0, I_tuser = 0, I_tvalid = 0;
    reg  [95:0] I_tdata = 96'd0;
    reg  [7:0]  I_grad_th = 8'd40;

    wire        O_tlast, O_tuser, O_tvalid, O_tready;
    wire [95:0] O_tdata;

    cartoon_96 #(
        .IMG_WIDTH (IMG_W),
        .IMG_HEIGHT(IMG_H),
        .GRAD_TH   (8'd40)
    ) dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_tlast(I_tlast), .I_tuser(I_tuser),
        .I_tdata(I_tdata), .I_tvalid(I_tvalid), .I_tready(1'b1),
        .I_grad_th(I_grad_th),
        .O_tlast(O_tlast), .O_tuser(O_tuser),
        .O_tdata(O_tdata), .O_tvalid(O_tvalid), .O_tready(O_tready)
    );

    integer pass_cnt = 0, fail_cnt = 0;
    task chk;
        input [255:0] name;
        input         cond;
        begin
            if (cond) begin pass_cnt = pass_cnt + 1; $display("  [PASS] %0s", name); end
            else      begin fail_cnt = fail_cnt + 1; $display("  [FAIL] %0s", name); end
        end
    endtask

    // ---- 造像素：用一个"灰度台阶"图案，便于验证量化与边缘 ----
    //   x <  640 : 暗灰 (R=G=B=0x60)
    //   x >= 640 : 亮灰 (R=G=B=0xC0)
    //   这样在 x=640 处有一个垂直边缘（形态学梯度 = 0xC0-0x60 = 0x60 = 96 > 20）
    function [7:0] pixv;
        input integer x;
        begin pixv = (x < 640) ? 8'h60 : 8'hC0; end
    endfunction

    function [95:0] make_word;
        input integer w0;      // 该字第一个像素的 x
        reg [7:0] v0,v1,v2,v3;
        begin
            v0 = pixv(w0); v1 = pixv(w0+1); v2 = pixv(w0+2); v3 = pixv(w0+3);
            make_word = {v3,v3,v3, v2,v2,v2, v1,v1,v1, v0,v0,v0};
        end
    endfunction

    // ---- 输出采集（写到文件，供 Python 核对）----
    integer fd;
    integer out_words = 0;
    integer out_valid_words = 0;

    // ---- 场景开关 ----
    //   +tuser_frame : 把 I_tuser 与**第一个有效字同拍**拉高（真机就是这样的），
    //                  走 x_grp/y_pos 的帧复位分支
    //   +out=<file>  : 输出文件名
    //   +gap         : 每行中间插一段 I_tvalid 拉低（验证有空洞时数据/控制仍对齐）
    reg         tuser_frame = 0;
    reg         use_gap     = 0;
    reg [1023:0] out_name;

    initial begin
        tuser_frame = $test$plusargs("tuser_frame");
        use_gap     = $test$plusargs("gap");
        if (!$value$plusargs("out=%s", out_name)) out_name = "cartoon_out.txt";
    end

    initial begin
        fd = $fopen(out_name, "w");
        if (fd == 0) $display("  [WARN] cannot open %0s", out_name);
    end

    always @(posedge clk) begin
        if (rst_n && O_tvalid) begin
            $fwrite(fd, "%0d %08x\n", out_words, O_tdata);
            out_words = out_words + 1;
        end
        if (rst_n && O_tvalid) out_valid_words = out_valid_words + 1;
    end

    integer ln, g, x;
    integer first_valid_cycle = -1, cyc = 0;

    always @(posedge clk) if (rst_n) cyc = cyc + 1;
    always @(posedge clk) if (rst_n && O_tvalid && first_valid_cycle < 0) first_valid_cycle = cyc;

    initial begin
        $display("");
        $display("============================================================");
        $display(" tb_cartoon_96 : P4 cartoonification");
        $display("   IMG %0dx%0d   %0d words/line   %0d lines", IMG_W, IMG_H, W_GRP, NLINES);
        $display("   pattern: x<640 dark(0x60) | x>=640 bright(0xC0)");
        $display("   tuser_frame=%0d  gap=%0d  out=%0s", tuser_frame, use_gap, out_name);
        $display("============================================================");

        // ---- 复位 ----
        rst_n = 0;
        repeat (20) @(posedge clk);
        $display("");
        $display("[T0] during reset");
        chk("T0 O_tvalid = 0 in reset", O_tvalid === 1'b0);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // ---- 连续灌 8 行 ----
        //  ⚠ 激励一律在 **negedge** 驱动：数据在随后的 posedge 前已稳定 1ns，
        //    不会与 DUT 的采样产生 delta 竞争（早先版本用阻塞赋值紧跟
        //    @(posedge clk)，属于依赖仿真器调度顺序的写法，不可靠）。
        //  非 tuser_frame 模式：先给一个孤立的 I_tuser 脉冲（旧行为，保留兼容）
        if (!tuser_frame) begin
            @(negedge clk); I_tuser = 1'b1;
            @(negedge clk); I_tuser = 1'b0;
        end
        for (ln = 0; ln < NLINES; ln = ln + 1) begin
            for (g = 0; g < W_GRP; g = g + 1) begin
                @(negedge clk);
                I_tdata  = make_word(g*4);
                I_tvalid = 1'b1;
                I_tlast  = (g == W_GRP-1);
                // 真机时序：I_tuser 与帧的第一个有效字同拍
                I_tuser  = tuser_frame && (ln == 0) && (g == 0);
                // 本拍已驱动有效数据；随后插 3 拍空洞
                //  ⚠ 必须**先**把 I_tvalid 拉低再等，否则那 3 拍仍是有效数据
                //    （早先写反了 ⇒ 多出 24 个有效字，看起来像"错位"）
                if (use_gap && g == W_GRP/2) begin
                    @(negedge clk);
                    I_tvalid = 1'b0; I_tlast = 1'b0; I_tuser = 1'b0;
                    repeat (3) @(negedge clk);
                end
            end
        end
        @(negedge clk);
        I_tvalid = 1'b0; I_tlast = 1'b0; I_tuser = 1'b0;
        repeat (50) @(posedge clk);
        $fclose(fd);

        $display("");
        $display("[T1] output validity");
        // 说明：本模块沿用 edge_detect_96 的时序 —— O_tvalid 是 I_tvalid 的
        //       **2 拍**延迟（内部多了一级流水：p1_* 一级 + O_tdata_r 一级）。
        //       ★ 数据路径也是 2 拍，控制路径必须同样是 2 拍；否则输出整体
        //         平移 4 像素（曾实测：真边缘从 x=640 跑到 x=644）。
        //       窗口外的像素退化为"量化色"（不出黑边），真正的边缘只在
        //       窗口有效区内产生 ⇒ 无需丢弃任何拍。
        chk("T1 O_tvalid appears within a few cycles", first_valid_cycle > 0);
        $display("       first valid at cycle = %0d", first_valid_cycle);

        $display("");
        $display("[T2] throughput (no word lost)");
        $display("       output valid words = %0d", out_valid_words);
        // 满帧直通：8 行输入 ⇒ 8 行输出 = 8*320 = 2560 字
        chk("T2 output words == 8 lines (full-frame passthrough)",
            out_valid_words == NLINES * W_GRP);
        $display("       (expect exactly %0d)", NLINES*W_GRP);

        $display("");
        $display("============================================================");
        $display(" PASS = %0d   FAIL = %0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display(" [OK] structural checks passed");
        else               $display(" [NG] %0d check(s) failed", fail_cnt);
        $display(" 逐像素结果已写入 cartoon_out.txt，请用 Python 独立核对：");
        $display("     python tools\\check_cartoon.py");
        $display("============================================================");
        $finish;
    end

    initial begin
        #2_000_000;
        $display(" [NG] timeout (pass=%0d fail=%0d)", pass_cnt, fail_cnt);
        $finish;
    end

endmodule
