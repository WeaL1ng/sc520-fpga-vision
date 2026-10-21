// ============================================================================
//  tb_gray_binary_96.v  ---  红线1 算法模块功能验证
//
//  被测：gray_binary_96（取代 Sobel 边缘检测，使赛题 2.3 基础要求②合规）
//        mode=0 原图直通 / 1 灰度 / 2 二值化 / 3 反色
//
//  验证内容
//    ① 时延恰为 1 拍（gray_binary_96.v:97-109 的输出寄存器）
//    ② mode=0 逐字节等于输入
//    ③ mode=1 三通道都等于 Y=(77R+150G+29B)>>8，且 R=G=B
//    ④ mode=2 按阈值判决（>th => 0xFF，否则 0x00）
//    ⑤ mode=3 逐字节取反
//    ⑥ tlast / tuser / tvalid 随数据同拍传递，O_tready 直通
//
//  时序约定（本 TB 自定，用于确认"1 拍时延"）：
//    在 negedge 改变输入 -> 下一个 posedge DUT 锁存 -> 该 posedge 之后读 O_tdata
//    若读到的是上一个字，则时延不是 1 拍（会由时延自检项报错）。
//
//  像素排布（与 awb / edge_detect_96 完全一致，这是能"直接替换"的前提）：
//    px0=[95:72]  px1=[71:48]  px2=[47:24]  px3=[23:0]，每组内 {R,G,B}
// ============================================================================
`timescale 1ns/1ps

module tb_gray_binary_96;

    localparam integer IMG_W = 1280;
    localparam integer IMG_H = 720;

    reg clk = 0, rst_n = 0;
    always #1 clk = ~clk;                      // 2ns 周期

    reg         I_tlast = 0, I_tuser = 0, I_tvalid = 0;
    reg  [95:0] I_tdata = 96'd0;
    reg  [1:0]  I_mode  = 2'd0;
    reg  [7:0]  I_th    = 8'd128;

    wire        O_tlast, O_tuser, O_tvalid, O_tready;
    wire [95:0] O_tdata;

    gray_binary_96 #(.IMG_WIDTH(IMG_W), .IMG_HEIGHT(IMG_H)) dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_tlast(I_tlast), .I_tuser(I_tuser),
        .I_tdata(I_tdata), .I_tvalid(I_tvalid), .I_tready(1'b1),
        .I_mode(I_mode), .I_threshold(I_th),
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

    // 按像素序号取 RGB（px0 在最高字节）
    function [7:0] px_r; input [95:0] w; input integer k;
        begin px_r = w[(3-k)*24 + 16 +: 8]; end
    endfunction
    function [7:0] px_g; input [95:0] w; input integer k;
        begin px_g = w[(3-k)*24 + 8 +: 8]; end
    endfunction
    function [7:0] px_b; input [95:0] w; input integer k;
        begin px_b = w[(3-k)*24 + 0 +: 8]; end
    endfunction

    // 参考模型：期望的灰度值
    function [7:0] exp_y; input [7:0] r; input [7:0] g; input [7:0] b;
        begin exp_y = (r*77 + g*150 + b*29) >> 8; end
    endfunction

    // 在 negedge 摆好输入，posedge 后取值 => 恰好 1 拍时延
    task drive; input [95:0] w; input l; input u; input v;
        begin
            @(negedge clk);
            I_tdata = w; I_tlast = l; I_tuser = u; I_tvalid = v;
        end
    endtask
    task capture; output [95:0] w; output l; output u; output v;
        begin
            @(posedge clk);
            #0.1;                       // 越过 NBA 更新
            w = O_tdata; l = O_tlast; u = O_tuser; v = O_tvalid;
        end
    endtask

    reg [95:0] w_in, w_out, w_prev, w_cur;
    reg        l_out, u_out, v_out;
    integer    k;
    integer    i;

    initial begin
        $display("");
        $display("============================================================");
        $display(" tb_gray_binary_96 : red-line 1 algorithm functional check");
        $display("   IMG %0dx%0d   mode 0=orig 1=gray 2=binary 3=invert", IMG_W, IMG_H);
        $display("============================================================");

        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // 已知像素组：{px0,px1,px2,px3}
        //   px0: R=200 G=100 B=50
        //   px1: R=10  G=20  B=30
        //   px2: R=255 G=255 B=255
        //   px3: R=0   G=0   B=0
        w_in = { 8'd200,8'd100,8'd50,  8'd10,8'd20,8'd30,
                 8'd255,8'd255,8'd255, 8'd0,8'd0,8'd0 };

        // ==============================================================
        // ⓞ 时延自检：先送一个"哨兵字"，再送目标字；1 拍后应读到目标字
        // ==============================================================
        $display("");
        $display("  ---- latency sanity (expect exactly 1 cycle) ----");
        I_mode = 2'd0;
        drive(96'hAAAAAAAAAAAAAAAAAAAAAAAA, 1'b0, 1'b0, 1'b1);
        capture(w_prev, l_out, u_out, v_out);            // 应锁存哨兵
        drive(w_in, 1'b0, 1'b0, 1'b1);
        capture(w_cur, l_out, u_out, v_out);             // 应锁存 w_in
        chk("latency == 1 cycle (sentinel then target)",
            w_prev === 96'hAAAAAAAAAAAAAAAAAAAAAAAA && w_cur === w_in);

        // ==============================================================
        // ① mode 0 原图直通
        // ==============================================================
        $display("");
        $display("  ---- mode 0 : original (passthrough) ----");
        I_mode = 2'd0;
        drive(w_in, 1'b1, 1'b1, 1'b1);
        capture(w_out, l_out, u_out, v_out);
        for (k = 0; k < 4; k = k + 1) begin
            chk("mode0 R passthrough", px_r(w_out,k) === px_r(w_in,k));
            chk("mode0 G passthrough", px_g(w_out,k) === px_g(w_in,k));
            chk("mode0 B passthrough", px_b(w_out,k) === px_b(w_in,k));
        end

        // ==============================================================
        // ② mode 1 灰度
        // ==============================================================
        $display("");
        $display("  ---- mode 1 : grayscale ----");
        I_mode = 2'd1;
        drive(w_in, 1'b0, 1'b0, 1'b1);
        capture(w_out, l_out, u_out, v_out);
        for (k = 0; k < 4; k = k + 1) begin
            chk("mode1 R==G", px_r(w_out,k) === px_g(w_out,k));
            chk("mode1 G==B", px_g(w_out,k) === px_b(w_out,k));
            chk("mode1 Y = (77R+150G+29B)>>8",
                px_r(w_out,k) === exp_y(px_r(w_in,k), px_g(w_in,k), px_b(w_in,k)));
        end

        // ==============================================================
        // ③ mode 2 二值化（th=128）
        // ==============================================================
        $display("");
        $display("  ---- mode 2 : binary, th=128 ----");
        I_mode = 2'd2; I_th = 8'd128;
        drive(w_in, 1'b0, 1'b0, 1'b1);
        capture(w_out, l_out, u_out, v_out);
        for (k = 0; k < 4; k = k + 1) begin
            chk("mode2 output is 00 or FF",
                px_r(w_out,k) === 8'h00 || px_r(w_out,k) === 8'hFF);
            chk("mode2 matches threshold",
                px_r(w_out,k) === ((exp_y(px_r(w_in,k),px_g(w_in,k),px_b(w_in,k)) > 8'd128)
                                   ? 8'hFF : 8'h00));
            chk("mode2 R=G=B",
                px_r(w_out,k) === px_g(w_out,k) && px_g(w_out,k) === px_b(w_out,k));
        end

        // ==============================================================
        // ④ mode 3 反色
        // ==============================================================
        $display("");
        $display("  ---- mode 3 : invert ----");
        I_mode = 2'd3;
        drive(w_in, 1'b0, 1'b0, 1'b1);
        capture(w_out, l_out, u_out, v_out);
        for (k = 0; k < 4; k = k + 1) begin
            chk("mode3 R inverted", px_r(w_out,k) === ~px_r(w_in,k));
            chk("mode3 G inverted", px_g(w_out,k) === ~px_g(w_in,k));
            chk("mode3 B inverted", px_b(w_out,k) === ~px_b(w_in,k));
        end

        // ==============================================================
        // ⑤ 阈值边界：Y=128 应黑（> 才白），Y=129 应白
        // ==============================================================
        $display("");
        $display("  ---- boundary: th=128, Y=128 -> 0x00 , Y=129 -> 0xFF ----");
        I_mode = 2'd2; I_th = 8'd128;
        // px0: R=G=B=128 => Y=128 ; px1: R=G=B=129 => Y=129
        w_in = { 8'd128,8'd128,8'd128,  8'd129,8'd129,8'd129,
                 8'd0,8'd0,8'd0,        8'd0,8'd0,8'd0 };
        drive(w_in, 1'b0, 1'b0, 1'b1);
        capture(w_out, l_out, u_out, v_out);
        chk("Y=128 -> 0x00 (not > th)", px_r(w_out,0) === 8'h00);
        chk("Y=129 -> 0xFF (> th)",     px_r(w_out,1) === 8'hFF);

        // ==============================================================
        // ⑥ 控制信号同拍传递
        // ==============================================================
        $display("");
        $display("  ---- control signals ----");
        I_mode = 2'd1;
        drive(w_in, 1'b1, 1'b1, 1'b1);
        capture(w_out, l_out, u_out, v_out);
        chk("tlast  follows data", l_out === 1'b1);
        chk("tuser  follows data", u_out === 1'b1);
        chk("tvalid follows data", v_out === 1'b1);
        chk("O_tready passthrough", O_tready === 1'b1);

        drive(w_in, 1'b0, 1'b0, 1'b0);
        capture(w_out, l_out, u_out, v_out);
        chk("tvalid deasserts when input invalid", v_out === 1'b0);

        // ==============================================================
        // ⑦ 连续背靠背 8 个字，确认无丢拍（吞吐 = 1 字/拍）
        //    驱动 8 拍 I_tvalid 恒高 -> 输出侧也应 8 拍恒高（仅整体延迟 1 拍）
        // ==============================================================
        $display("");
        $display("  ---- back-to-back throughput (8 words, I_tvalid held high) ----");
        I_mode = 2'd1;
        begin : b2b
            integer n;
            integer ok_cnt;
            ok_cnt = 0;
            for (n = 0; n < 8; n = n + 1) begin
                @(negedge clk);
                I_tdata  = { 8'd10*n, 8'd10*n, 8'd10*n,  8'd20*n, 8'd20*n, 8'd20*n,
                             8'd30*n, 8'd30*n, 8'd30*n,  8'd40*n, 8'd40*n, 8'd40*n };
                I_tlast  = 1'b0;
                I_tuser  = 1'b0;
                I_tvalid = 1'b1;                 // 恒高，无间隙
                @(posedge clk); #0.1;
                if (O_tvalid === 1'b1) ok_cnt = ok_cnt + 1;
            end
            chk("b2b: O_tvalid high on all 8 consecutive cycles", ok_cnt == 8);
            @(negedge clk);
            I_tvalid = 1'b0; I_tdata = 96'd0;
            @(posedge clk); #0.1;
            chk("b2b: O_tvalid drops after input stops", O_tvalid === 1'b0);
        end

        $display("");
        $display("============================================================");
        $display("  PASS = %0d   FAIL = %0d", pass_cnt, fail_cnt);
        if (fail_cnt == 0) $display("  [OK] all checks passed");
        else               $display("  [NG] %0d check(s) failed", fail_cnt);
        $display("============================================================");
        $finish;
    end

    initial begin
        #200000;
        $display("  [NG] timeout (pass=%0d fail=%0d)", pass_cnt, fail_cnt);
        $finish;
    end

endmodule
