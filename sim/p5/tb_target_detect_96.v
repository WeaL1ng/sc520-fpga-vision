// ============================================================================
//  tb_target_detect_96.v  ---  P5 颜色目标检测 功能验证
//
//  验证方式（沿用本项目"多软件交叉"的做法）
//    ① ModelSim 灌入**合成图案**（已知目标位置/大小/颜色），导出每帧的
//       包围框/命中 tile 数/形状到文本文件；
//    ② Python 用**独立实现**的期望模型（不复用 RTL 任何函数）从图案定义
//       直接算出期望包围框，逐帧比对。
//
//  ★ 为什么必须独立比对
//    这个项目已经两次栽在"模块级断言全过、上板才发现错"上（P3 延迟算法、
//    时间基准频率）。tile 量化 + 阈值 + 增量 min/max 这类逻辑，
//    光看"有没有框"根本发现不了**边界差 1 个 tile**这种错。
//
//  图案（场景由 plusarg 选）
//    A  橙块   x∈[320,479]  y∈[160,319]   ⇒ 期望 bbox 像素 (311,151)-(488,328)
//                                             （tile 量化后外扩到 tile 边界）
//    B  蓝块   （不应被检出）
//    C  肤色块 （不应被检出 —— 验证 Cr 阈值排除了肤色）
//    D  橙色长条 x∈[80,719] y∈[400,479]  ⇒ 期望判成 BAR
//    E  无目标 ⇒ O_valid=0
//
//  用法：
//     vsim -batch -lib work tb_target_detect_96 -do "run -all; quit -f" +scene=A
// ============================================================================
`timescale 1ns/1ps

module tb_target_detect_96;

    localparam integer IMG_W  = 1280;
    localparam integer IMG_H  = 720;
    localparam integer W_GRP  = IMG_W / 4;      // 320 拍/行
    localparam integer NFRAMES = 3;             // 跑 3 帧（验证跨帧结算）

    reg clk = 0, rst_n = 0;
    always #1 clk = ~clk;                       // 500 MHz 虚拟，随便给

    reg         I_tlast = 0, I_tuser = 0, I_tvalid = 0;
    reg  [95:0] I_tdata = 96'd0;

    wire [10:0] O_x_min, O_x_max;
    wire [9:0]  O_y_min, O_y_max;
    wire [7:0]  O_tile_cnt;
    wire [1:0]  O_shape;
    wire        O_valid, O_frame_start;
    wire [3:0]  O_x_min_d3, O_x_min_d2, O_x_min_d1, O_x_min_d0;
    wire [3:0]  O_y_min_d2, O_y_min_d1, O_y_min_d0;
    wire [7:0]  O_dbg_beat;
    wire [19:0] O_dbg_warm;
    wire [7:0]  O_dbg_cb, O_dbg_cr;

    target_detect_96 #(
        .IMG_WIDTH (IMG_W),
        .IMG_HEIGHT(IMG_H)
    ) dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_tlast(I_tlast), .I_tuser(I_tuser),
        .I_tdata(I_tdata), .I_tvalid(I_tvalid), .I_tready(1'b1),
        .O_x_min(O_x_min), .O_x_max(O_x_max),
        .O_y_min(O_y_min), .O_y_max(O_y_max),
        .O_tile_cnt(O_tile_cnt), .O_shape(O_shape),
        .O_valid(O_valid), .O_frame_start(O_frame_start),
        .O_x_min_d3(O_x_min_d3), .O_x_min_d2(O_x_min_d2),
        .O_x_min_d1(O_x_min_d1), .O_x_min_d0(O_x_min_d0),
        .O_y_min_d2(O_y_min_d2), .O_y_min_d1(O_y_min_d1), .O_y_min_d0(O_y_min_d0),
        .O_dbg_beat_k(O_dbg_beat), .O_dbg_warm(O_dbg_warm),
        .O_dbg_cb(O_dbg_cb), .O_dbg_cr(O_dbg_cr)
    );

    // ---- 场景选择（默认 'A'；plusarg 失败也不会变成 0）----
    reg [7:0] scene = 8'h41;                 // 'A'
    integer   plus_dummy;
    initial begin
        plus_dummy = $value$plusargs("scene=%s", scene);
    end

    // ★ 相位偏移启动：先灌 phase 拍**帧中间的数据**（当作复位释放时的任意相位），
    //   然后才来第一个 tuser。对齐逻辑正确时，最终包围框必须与 phase=0 时**完全一致**。
    //   ⚠ 变量必须声明在所有 initial 之前，且 plusarg 在主激励块最前面读
    //     （踩过"跨 initial 竞争拿到 X"的坑）。
    integer phase_off = 0;
    integer tuser_on  = 1;      // 1 = 发 tuser 做帧相位对齐；0 = 不发（对照组）

    // ---- 颜色（Verilog 函数必须至少有一个输入 ⇒ 常量用 localparam）----
    localparam [23:0] C_BG   = 24'h30_30_30;   // 暗灰（非暖色）
    localparam [23:0] C_ORNG = 24'hFF_80_00;   // 橙
    localparam [23:0] C_BLUE = 24'h00_00_FF;   // 蓝
    localparam [23:0] C_SKIN = 24'hAA_8C_78;   // 肤色 (170,140,120) 贴近实测：不应检出
    localparam [23:0] C_SKNS = 24'hC8_96_78;   // 偏饱和肤色 (200,150,120)：**会**检出（边界，如实标注）
    //  ★ 2026-09-23：过曝兜底判据的两个对照场景
    //     F 过曝橙 (255,230,200)：Cr 只有 142 < 160，旧判据判不出来 ⇒ 必须靠新判据②检出
    //     G 过曝白 (255,255,255)：R==G==B ⇒ **必须不检出**（否则新判据就成了"见白就报"）
    localparam [23:0] C_OORG = 24'hFF_E6_C8;   // 过曝橙 (255,230,200)
    localparam [23:0] C_OWHT = 24'hFF_FF_FF;   // 过曝白 (255,255,255)
    //  ★ 2026-09-26：哑光橙臂章与纯黄（配合 CB_MIN=30 / CR_MIN=146 的改动）
    //     H 哑光橙 (170,125,100)：**应检出**（这是赛题要认的目标）
    //     I 纯黄   (255,255,0)  ：**必须不检出**（Cb=0 被 CB_MIN 挡，Cr=148 挡不住它）
    localparam [23:0] C_ARMB = 24'hAA_7D_64;   // 哑光橙臂章 (170,125,100)
    localparam [23:0] C_YELL = 24'hFF_FF_00;   // 纯黄 (255,255,0)
    //  2026-09-26 第二次上板反馈：变暗就认不出
    //     J 变暗的臂章 (85,62,50)  ：**应检出**（判据(3) 守门）
    //     K 变暗的肤色 (140,105,84)：应 **不**检出
    localparam [23:0] C_DARM = 24'h55_3E_32;   // 变暗臂章 (85,62,50)
    localparam [23:0] C_DSKN = 24'h8C_69_54;   // 变暗肤色 (140,105,84)

    // ---- 像素判决（按场景）----
    function [23:0] pix;
        input integer x, y;
        begin
            pix = C_BG;
            case (scene)
                "A": if (x >= 320 && x <= 479 && y >= 160 && y <= 319) pix = C_ORNG;
                "B": if (x >= 320 && x <= 479 && y >= 160 && y <= 319) pix = C_BLUE;
                "C": if (x >= 320 && x <= 479 && y >= 160 && y <= 319) pix = C_SKIN;
                "D": if (x >=  80 && x <= 719 && y >= 400 && y <= 479) pix = C_ORNG;
                "F": if (x >= 320 && x <= 479 && y >= 160 && y <= 319) pix = C_OORG;
                "G": if (x >= 320 && x <= 479 && y >= 160 && y <= 319) pix = C_OWHT;
                "H": if (x >= 320 && x <= 479 && y >= 160 && y <= 319) pix = C_ARMB;
                "I": if (x >= 320 && x <= 479 && y >= 160 && y <= 319) pix = C_YELL;
                "J": if (x >= 320 && x <= 479 && y >= 160 && y <= 319) pix = C_DARM;
                "K": if (x >= 320 && x <= 479 && y >= 160 && y <= 319) pix = C_DSKN;
                "L": if (x >= 320 && x <= 479 && y >= 160 && y <= 319) pix = C_SKNS;
                "E": pix = C_BG;
                default: pix = C_BG;
            endcase
        end
    endfunction

    function [95:0] make_word;
        input integer w0;
        reg [23:0] v0,v1,v2,v3;
        begin
            v0 = pix(w0,   cur_y); v1 = pix(w0+1, cur_y);
            v2 = pix(w0+2, cur_y); v3 = pix(w0+3, cur_y);
            make_word = {v3, v2, v1, v0};
        end
    endfunction

    // ---- 临时调试：帧末（累加器还没被清）时的内部量 ----
    //   （BCD 位宽陷阱排查用，已保留但默认关闭；需要时把 define 打开）
    // `define DBG_TGT
`ifdef DBG_TGT
    always @(posedge clk) begin
        if (rst_n && I_tvalid && I_tlast &&
            (dut.P_tile_y == 4'd8) && (dut.P_line == 7'd79))
            $display("      [eof] tx_min=%0d tx_max=%0d w_xmin=%0d x_rest=%0d x_lo=%h y_lo=%h any=%b",
                     dut.tx_min, dut.tx_max, dut.w_xmin, dut.x_rest,
                     dut.x_lo, dut.y_lo, dut.any_hit);
    end
`endif

    // ---- 输出记录（每帧一行）----
    integer      fd, frame_no = 0;
    reg [1023:0] out_name;
    initial begin
        if (!$value$plusargs("out=%s", out_name)) out_name = "target_out.txt";
        fd = $fopen(out_name, "w");
        if (fd == 0) $display("  [WARN] cannot open %0s", out_name);
    end

    always @(posedge clk) begin
        if (rst_n && O_frame_start) begin
            $fwrite(fd, "%0d %0d %0d %0d %0d %0d %0d %0d %0d%0d%0d%0d %0d%0d%0d\n",
                    frame_no, O_valid, O_x_min, O_x_max, O_y_min, O_y_max,
                    O_tile_cnt, O_shape,
                    O_x_min_d3, O_x_min_d2, O_x_min_d1, O_x_min_d0,
                    O_y_min_d2, O_y_min_d1, O_y_min_d0);
            $display("  [frame %0d] valid=%0d bbox=(%0d,%0d)-(%0d,%0d) tiles=%0d shape=%0d  BCD x=%0d%0d%0d%0d y=%0d%0d%0d  DBG B%02h W%05h C%02h/%02h",
                     frame_no, O_valid, O_x_min, O_y_min, O_x_max, O_y_max,
                     O_tile_cnt, O_shape,
                     O_x_min_d3, O_x_min_d2, O_x_min_d1, O_x_min_d0,
                     O_y_min_d2, O_y_min_d1, O_y_min_d0,
                     O_dbg_beat, O_dbg_warm, O_dbg_cb, O_dbg_cr);
            frame_no = frame_no + 1;
        end
    end

    integer ln, g, cur_y, p;
    reg [95:0] ramp_off = 96'd0;
    integer f;
    initial begin
        plus_dummy = $value$plusargs("phase=%d", phase_off);   // ★ 必须在最前面读
        plus_dummy = $value$plusargs("tuser=%d", tuser_on);
        $display("");
        $display("============================================================");
        $display(" tb_target_detect_96 : scene=%0s  phase_off=%0d  tuser=%0d",
                 scene, phase_off, tuser_on);
        $display("============================================================");

        rst_n = 0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // ---- ★ 相位偏移：先空转 phase_off 拍（内容随意，只为把计数器推到中间）----
        //   这一段**不发 tuser**，所以只有靠 tuser 对齐才能纠正它。
        for (p = 0; p < phase_off; p = p + 1) begin
            @(negedge clk);
            I_tdata  = ramp_off; I_tvalid = 1'b1; I_tuser = 1'b0; I_tlast = 1'b0;
        end

        for (f = 0; f < NFRAMES; f = f + 1) begin
            for (ln = 0; ln < IMG_H; ln = ln + 1) begin
                cur_y = ln;
                for (g = 0; g < W_GRP; g = g + 1) begin
                    @(negedge clk);
                    I_tdata  = make_word(g*4);
                    I_tvalid = 1'b1;
                    I_tlast  = (g == W_GRP-1);
                    I_tuser  = tuser_on && (ln == 0) && (g == 0);  // 帧首（可关闭以做对照）
                end
            end
        end
        // ⚠ 结算发生在 **tuser**（下一帧帧首）⇒ 最后一帧需要额外补一个 tuser 才能落盘。
        //   于是记录数 = NFRAMES + 1，其中**第 0 条是复位后的空帧**（valid 应为 0），
        //   Python 侧按此约定核对。
        @(negedge clk);
        I_tdata = 96'd0; I_tvalid = 1'b1; I_tuser = 1'b1; I_tlast = 1'b0;
        @(negedge clk);
        I_tvalid = 1'b0; I_tlast = 1'b0; I_tuser = 1'b0;
        repeat (10) @(posedge clk);
        $fclose(fd);

        $display("");
        $display(" 共输出 %0d 帧结果 = NFRAMES(%0d) + 1（第 0 条为复位后空帧）",
                 frame_no, NFRAMES);
        $display(" 逐帧结果已写入 target_out.txt，请用 Python 独立核对：");
        $display("     python tools\\check_target_detect.py --scene %0s", scene);
        $display("============================================================");
        $finish;
    end

    initial begin
        #200_000_000;
        $display(" [NG] timeout");
        $finish;
    end

endmodule
