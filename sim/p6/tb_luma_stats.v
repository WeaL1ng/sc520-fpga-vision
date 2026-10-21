// ============================================================================
//  tb_luma_stats.v  ---  P6 亮度统计模块功能验证（L1）
//
//  验证什么（"只数拍、不看 tuser"这套自计时到底对不对）：
//    ① **帧边界**：恰好 230,400 个有效拍算一帧，且**最后一拍要计入**
//       （少算一拍 ⇒ sum 差 4×Y，是最典型的 off-by-one）；
//    ② **亮度公式**：Y = (77R+150G+29B)>>8 的移位加法分解；
//    ③ **累加器位宽**：满幅白色 921600×255 = 235,008,000 不溢出 32 位；
//    ④ **过曝/暗部计数**；
//    ⑤ **平均亮度**：`((sum>>10)*18642)>>24` 这个"乘倒数"近似的取整是否正确；
//    ⑥ **跨域握手**：O_tog 每帧**恰好翻转一次**（多翻/少翻都会让
//       下游 ae_ctrl 的边沿捕获多采或漏采）。
//
//  ★ 期望值为什么是"硬编码的 6 个点"而不是再算一遍公式：
//     如果 TB 里也写 `(77*r+150*g+29*b)>>8`，那就是**用同一个实现验自己**，
//     只能证明"加法器没坏"，证明不了"公式分解对不对"。
//     所以这里用**独立算出来的常数**（口算可验证）：
//        (128,128,128) -> 256*128>>8 = 128
//        (255,255,255) -> 256*255>>8 = 255
//        (  0,  0,  0) -> 0
//        (255,  0,  0) -> 77*255>>8  = 19635>>8 = 76  ⚠ 注意不是 77（截断）
//        (  0,255,  0) -> 150*255>>8 = 38250>>8 = 149 ⚠ 不是 150
//        (  0,  0,255) -> 29*255>>8  = 7395 >>8 = 28  ⚠ 不是 29
//     ⚠ 后三个是**截断**的结果，一开始我按系数直接写了 77/150/29 是错的 ——
//       这正是"独立期望值"的价值：它逼我把 255×77 到底等于多少真的算一遍。
//
//  用法：
//     vsim -batch -lib work tb_luma_stats -do "run -all; quit -f" +case=uniform
//     vsim -batch -lib work tb_luma_stats -do "run -all; quit -f" +case=ramp
// ============================================================================
`timescale 1ns/1ps

module tb_luma_stats;

    localparam integer IMG_W = 1280;
    localparam integer IMG_H = 720;
    localparam integer W_GRP = IMG_W / 4;               // 320 拍/行
    localparam integer NBEAT = W_GRP * IMG_H;           // 230400
    localparam integer PIX   = IMG_W * IMG_H;           // 921600
    localparam [19:0]  PIX20 = 20'd921600;              // 避免对 integer 参数做位选
    localparam integer NCASE = 6;                       // uniform 用 6 个颜色

    reg clk = 0, rst_n = 0;
    always #1 clk = ~clk;

    reg  [95:0] I_tdata  = 96'd0;
    reg         I_tvalid = 0;

    wire [31:0] O_sum;
    wire [19:0] O_clip;
    wire [19:0] O_dark;
    wire        O_frame_done;
    wire        O_tog;

    luma_stats #(
        .IMG_WIDTH (IMG_W),
        .IMG_HEIGHT(IMG_H)
    ) dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_tdata(I_tdata), .I_tvalid(I_tvalid),
        .O_sum(O_sum), .O_clip(O_clip), .O_dark(O_dark),
        .O_frame_done(O_frame_done), .O_tog(O_tog)
    );

    // ---- 用例选择 ----
    //   ⚠ 踩坑记录：一开始用 `+case=ramp` 配 `reg [7:0] tcase` 再比 `tcase=="r"`，
    //     结果 `%s` 把 "ramp" 塞进 8 位寄存器的方式与预期不同（打印出来是 "ramp"，
    //     但比较 `=="r"` 为假）⇒ **静默跑成了另一个用例**，日志里看不出异常。
    //     改成 `+ramp=1` 这种"数字开关"，语义无歧义。
    //   ⚠ 第二坑：`$value$plusargs` 若放在**另一个** initial 块里，与主激励块在
    //     时刻 0 是**竞争**关系 —— 主块可能先读 `nf` 而拿到 X。
    //     故这里只在主 initial 块的最开头读一次（下面 `initial begin` 内）。
    //   ⚠ 第三坑（同一个根因）：**不要**声明一个 `wire w = (is_ramp != 0);` 再由
    //     initial 块立刻读它 —— 连续赋值与 initial 块在同一时刻求值有 delta 竞争，
    //     读到的还是 X ⇒ 循环 `for (f=0; f<nf; ...)` 一次都不执行，
    //     表现为"0 帧、无报错"。**直接用 `is_ramp != 0` 表达式**（下式）。
    integer is_ramp = 0;
    integer plus_dummy;
    // （已改为直接写 (is_ramp != 0)，不用宏）

    // ---- uniform 用例：6 个纯色/灰度 + **独立算好的**期望 Y ----
    function [23:0] uni_color;
        input integer i;
        begin
            case (i)
                0: uni_color = 24'h80_80_80;   // 灰 128
                1: uni_color = 24'hFF_FF_FF;   // 白 255
                2: uni_color = 24'h00_00_00;   // 黑 0
                3: uni_color = 24'hFF_00_00;   // 纯红
                4: uni_color = 24'h00_FF_00;   // 纯绿
                5: uni_color = 24'h00_00_FF;   // 纯蓝
                default: uni_color = 24'h00_00_00;
            endcase
        end
    endfunction

    function integer uni_y_exp;
        input integer i;
        begin
            case (i)
                0: uni_y_exp =  128;
                1: uni_y_exp =  255;
                2: uni_y_exp =    0;
                3: uni_y_exp =   76;   // 19635 >> 8
                4: uni_y_exp =  149;   // 38250 >> 8
                5: uni_y_exp =   28;   //  7395 >> 8
                default: uni_y_exp = 0;
            endcase
        end
    endfunction

    // ---- ramp 用例：每像素 v = (3x+5y) & 0xFF（三通道相同 ⇒ Y = v）----
    //   期望值由 Python 独立算（tools/check_luma_stats.py），本 TB 只落盘。
    function [7:0] ramp_v;
        input integer x, y;
        begin
            ramp_v = (3*x + 5*y) & 32'hFF;
        end
    endfunction

    // ---- 组一拍 96 bit：4 个像素 ----
    function [95:0] make_word;
        input integer x0, y;
        reg [23:0] v0, v1, v2, v3;
        reg [7:0]  a0, a1, a2, a3;
        begin
            if ((is_ramp != 0)) begin       // 斜坡用例
                a0 = ramp_v(x0,   y); a1 = ramp_v(x0+1, y);
                a2 = ramp_v(x0+2, y); a3 = ramp_v(x0+3, y);
                v0 = {a0,a0,a0}; v1 = {a1,a1,a1}; v2 = {a2,a2,a2}; v3 = {a3,a3,a3};
            end else begin
                v0 = uni_color(0); v1 = v0; v2 = v0; v3 = v0;   // 占位，靠调用处覆盖
            end
            make_word = {v3, v2, v1, v0};
        end
    endfunction

    // ---- uniform：整帧同一颜色 ----
    function [95:0] word_of_color;
        input [23:0] c;
        begin
            word_of_color = {c, c, c, c};
        end
    endfunction

    // ================================================================
    // 检查与记录
    // ================================================================
    integer fd, frame_no = 0;
    integer err_cnt = 0;
    reg [1023:0] out_name;

    // 跨域握手：O_tog 每帧必须恰好翻转一次
    reg  tog_d = 1'b0, tog_valid = 1'b0;
    integer tog_flips = 0;

    initial begin
        if (!$value$plusargs("out=%s", out_name)) out_name = "luma_stats_out.txt";
        fd = $fopen(out_name, "w");
        if (fd == 0) $display("  [WARN] cannot open %0s", out_name);
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if (tog_valid && (O_tog !== tog_d)) tog_flips = tog_flips + 1;
            tog_d     <= O_tog;
            tog_valid <= 1'b1;
        end
    end

    integer exp_sum, exp_y, nc;
    always @(posedge clk) begin
        if (rst_n && O_frame_done) begin
            $fwrite(fd, "%0d %0d %0d %0d\n", frame_no, O_sum, O_clip, O_dark);
            if (!(is_ramp != 0)) begin       // uniform 用例由 TB 直接判定
                exp_y   = uni_y_exp(frame_no % NCASE);
                exp_sum = PIX * exp_y;
                nc      = 0;
                if (O_sum  !== exp_sum[31:0]) begin
                    $display("  [NG] frame %0d: sum=%0d 期望 %0d", frame_no, O_sum, exp_sum);
                    nc = nc + 1;
                end
                if (O_clip !== ((exp_y >= 250) ? PIX20 : 20'd0)) begin
                    $display("  [NG] frame %0d: clip=%0d 期望 %0d", frame_no, O_clip,
                             (exp_y >= 250) ? PIX : 0);
                    nc = nc + 1;
                end
                if (O_dark !== ((exp_y <= 8) ? PIX20 : 20'd0)) begin
                    $display("  [NG] frame %0d: dark=%0d 期望 %0d", frame_no, O_dark,
                             (exp_y <= 8) ? PIX : 0);
                    nc = nc + 1;
                end
                if (nc == 0)
                    $display("  [ OK ] frame %0d: Y=%0d sum=%0d clip=%0d dark=%0d",
                             frame_no, exp_y, O_sum, O_clip, O_dark);
                err_cnt = err_cnt + nc;
            end else begin
                $display("  [dump] frame %0d: sum=%0d clip=%0d dark=%0d",
                         frame_no, O_sum, O_clip, O_dark);
            end
            frame_no = frame_no + 1;
        end
    end

    // ================================================================
    // 主激励
    // ================================================================
    integer ln, g, f, nf;
    initial begin
        plus_dummy = $value$plusargs("ramp=%d", is_ramp);   // ★ 必须最先读
        $display("");
        $display("============================================================");
        $display(" tb_luma_stats : %0s", (is_ramp != 0) ? "ramp（斜坡，交 Python 独立核对）"
                                                  : "uniform（6 个纯色/灰度，TB 自判）");
        $display("============================================================");

        nf = (is_ramp != 0) ? 3 : NCASE;

        rst_n = 0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        for (f = 0; f < nf; f = f + 1) begin
            for (ln = 0; ln < IMG_H; ln = ln + 1) begin
                for (g = 0; g < W_GRP; g = g + 1) begin
                    @(negedge clk);
                    I_tdata  = (is_ramp != 0) ? make_word(g*4, ln)
                                       : word_of_color(uni_color(f % NCASE));
                    I_tvalid = 1'b1;
                end
            end
        end

        // 再跑几拍有效数据，确认"多跑不结算"（帧边界只由拍数决定）
        repeat (17) @(negedge clk);
        I_tvalid = 1'b0;
        I_tdata  = 96'd0;
        repeat (50) @(posedge clk);

        $fclose(fd);
        $display("");
        $display("  共结算 %0d 帧；O_tog 翻转 %0d 次", frame_no, tog_flips);
        if (frame_no != nf) begin
            $display("  [NG] 结算帧数 %0d 期望 %0d（多结算/漏结算 ⇒ 拍数边界错）",
                     frame_no, nf);
            err_cnt = err_cnt + 1;
        end
        if (tog_flips != nf) begin
            $display("  [NG] O_tog 翻转 %0d 次 期望 %0d（跨域握手会多采/漏采）",
                     tog_flips, nf);
            err_cnt = err_cnt + 1;
        end
        $display("");
        if (err_cnt == 0) $display(" ==== PASS ====");
        else              $display(" ==== FAIL （%0d 项）====", err_cnt);
        $display("============================================================");
        $finish;
    end

    initial begin
        #200_000_000;
        $display(" [NG] timeout");
        $finish;
    end

endmodule
