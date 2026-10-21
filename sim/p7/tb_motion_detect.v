// ============================================================================
//  tb_motion_detect.v  ---  P7 运动目标检测 功能验证
//
//  验证方式（沿用本项目"多软件交叉"的做法）
//    ① ModelSim 灌入**合成图案**（逐帧已知：静止 / 运动 / 亮度阶跃 / 孤立噪声 /
//       物体移出 / 垂直有结构的静止画面 / 加噪静止画面），导出每帧的
//       valid / 全局突变标志 / 原始块数 / 腐蚀后块数 / 包围框到文本文件；
//    ② Python（tools/check_motion_detect.py）用**独立实现**从图案定义逐帧重算
//       块亮度、|diff|、sigma-delta 背景、2×2 腐蚀、包围框、块数，逐帧比对。
//
//  ★ 为什么必须独立比对
//    "有没有框"这种粗检查发现不了 sigma-delta 背景慢跟踪几帧后的偏差、
//    块边界差一个块、腐蚀漏掉边界行这类错。P5 就是靠 Python 独立模型抓出
//    "列计数永久错开一拍"的。
//
//  ★★ 2026-09-26 上板事故补场景 F/G/H（本次新增，最重要的一节）
//    事故现象：**静止场景也出框**。根因是背景"按列共享 160 槽"——
//    同一列上下亮度差 > MOT_TH 时背景被拖走，静止画面里的**水平分界处**
//    那一列会长期报运动。原来的 A~E 五个场景背景**垂直均匀**（纯色底 +
//    一个移动块），恰好是按列共享能工作的唯一情形 ⇒ **这个 bug 在 L1 里
//    结构性看不见**。这与 P5 "TB 总从帧第 0 拍开始灌、于是相位 bug 仿真
//    永远不出现"是**同一类错误**：测试激励没覆盖真实条件。
//    ⇒ 新增：
//      F 静止 + 垂直结构（上半亮 200 / 下半暗 40，水平分界）⇒ 必须全程 valid=0
//      G 静止 + 多条水平带 + 垂直渐变            ⇒ 必须全程 valid=0
//      H 静止 + 每像素噪声 ±N（N=8/16/24）        ⇒ 必须全程 valid=0（定 MOT_TH）
//
//  场景（由 plusarg 选；每帧的图案都与帧号有关）
//    A 静止       整帧恒定                        ⇒ 全程 valid=0、cnt=0
//    B 块移动     前 2 帧全黑，第 3 帧起 [320,479]×[160,319] 变亮
//                                                ⇒ 出框，原始 400 块 / 腐蚀后 361 块
//    C 全局阶跃   第 2 帧起**所有**像素 +40（模拟 AE 动一下，P6 之后必然发生）
//                                                ⇒ 必须 valid=0（验证全局突变抑制）
//    D 孤立噪声   第 3 帧起只有**一个** 8×8 块变亮
//                                                ⇒ 被 2×2 腐蚀去掉，valid=0、
//                                                  原始块数=1 而腐蚀后=0
//    E 物体移出   第 3~4 帧有运动块，第 5 帧起恢复背景 ⇒ 框消失、计数回 0
//    F 垂直结构静止 ⇒ 必须全程 valid=0（上板事故的直接回归用例）
//    G 带+渐变静止  ⇒ 必须全程 valid=0
//    H 噪声静止     ⇒ 必须全程 valid=0
//
//  相位用例（两种，缺一不可）
//    +phase=N  先空转 N 拍（这段**不发 tuser**，把自计时相位推到帧中间），
//              再正常发 tuser ⇒ 对齐正确时每帧结果必须与 phase=0 **完全一致**
//    +tuser=0  完全不发 tuser（纯自计时对照）。复位相位本来就对时结果应一致；
//              配合 +phase=N 时结果必然错位 —— 那是**对照组**，用 +ctrl=1 标注，
//              不算失败。
//
//  用法：
//     vsim -batch -lib work tb_motion_detect -do "run -all; quit -f" \
//          "+scene=F" "+out=f.txt" [+phase=3000] [+tuser=1] [+frames=6] \
//          [+noise=24] [+ctrl=0]
// ============================================================================
`timescale 1ns/1ps

module tb_motion_detect;

    localparam integer IMG_W   = 1280;
    localparam integer IMG_H   = 720;
    localparam integer W_GRP   = IMG_W / 4;      // 320 拍/行

    // 亮度（只灌 G 通道有意义的图案；R=B=G，因为本模块**只用 G**）
    localparam [7:0] L_BG  = 8'd40;              // 背景亮度
    localparam [7:0] L_MOT = 8'd200;             // 运动区域亮度（差 160 ≫ MOT_TH=18）
    localparam [7:0] L_JUMP = 8'd40;             // 场景 C 的亮度阶跃量
    localparam [7:0] L_TOP = 8'd200;             // 场景 F/G 的亮部
    localparam [7:0] L_BOT = 8'd40;              // 场景 F 的暗部
    localparam [7:0] L_MID = 8'd120;             // 场景 H 的静态底

    reg clk = 0, rst_n = 0;
    always #1 clk = ~clk;                        // 周期 2 ns（虚拟频率，不影响功能）

    reg         I_tuser = 0, I_tvalid = 0;
    reg  [95:0] I_tdata = 96'd0;

    wire [10:0] O_x_min, O_x_max;
    wire [9:0]  O_y_min, O_y_max;
    wire [13:0] O_blk_cnt;
    wire        O_valid, O_global_chg, O_frame_start;
    wire [13:0] O_motion_raw;

    motion_detect #(
        .IMG_WIDTH (IMG_W),
        .IMG_HEIGHT(IMG_H)
    ) dut (
        .I_clk(clk), .I_rst_n(rst_n), .I_tuser(I_tuser),
        .I_tdata(I_tdata), .I_tvalid(I_tvalid),
        .O_x_min(O_x_min), .O_x_max(O_x_max),
        .O_y_min(O_y_min), .O_y_max(O_y_max),
        .O_blk_cnt(O_blk_cnt),
        .O_valid(O_valid), .O_global_chg(O_global_chg),
        .O_frame_start(O_frame_start), .O_motion_raw(O_motion_raw)
    );

    // ---- plusarg（★ 必须在所有 initial 之前声明；读取放在主激励块最前面，
    //      踩过"跨 initial 竞争拿到 X"的坑）----
    reg [7:0] scene    = 8'h41;    // 'A'
    integer   plus_dummy;
    integer   phase_off = 0;       // 先空转多少拍（这段时间不发 tuser）
    integer   tuser_on  = 1;       // 1=发 tuser 做相位对齐；0=纯自计时对照
    integer   ctrl_mode = 0;       // 1=对照组（允许与期望不一致，只标注不判失败）
    integer   nfr       = 6;       // 跑多少帧（+frames=N；噪声研究用 12）
    integer   noise_n   = 16;      // 场景 H 的噪声幅度 ±N（+noise=N）

    // ================================================================ 场景图案
    //  ★ 噪声为什么不用 $random：
    //    $random 的算法没有标准、Python **无法复现同一条序列** ⇒ 那样
    //    "独立模型"就只能比对而不能重算，等于放弃交叉验证。
    //    这里用**确定性整数 hash**（只含移位/XOR/加 + 32 位掩码），
    //    Python 侧逐位复现同一条序列（见 check_motion_detect.py 的 nz_mix）。
    function [31:0] nz_mix;
        input [31:0] a;
        reg   [31:0] h;
        begin
            h = a;
            h = h ^ (h << 13);
            h = h + 32'h9E37_79B9;
            h = h ^ (h >> 17);
            h = h + 32'h7F4A_7C15;
            h = h ^ (h << 5);
            nz_mix = h;
        end
    endfunction

    // 场景 H 的像素：静态底 ±N 的确定性噪声
    function [7:0] luma_noise;
        input integer x, y, f;
        reg [31:0] a, h;
        begin
            a = (x << 20) + (y << 8) + f;      // x<2048、y<1024、f<16 ⇒ 位域不重叠
            h = nz_mix(a);
            luma_noise = L_MID + ((h >> 8) % ((noise_n << 1) + 1)) - noise_n;
        end
    endfunction

    // 场景 G 的水平亮度带
    function [7:0] band_g;
        input integer y;
        begin
            if      (y < 120) band_g = 8'd220;
            else if (y < 240) band_g = 8'd170;
            else if (y < 480) band_g = 8'd110;
            else if (y < 600) band_g = 8'd70;
            else              band_g = 8'd40;
        end
    endfunction

    integer cur_y = 0;
    function [7:0] luma;
        input integer x, y, f;
        reg [7:0] v;
        begin
            v = L_BG;
            case (scene)
                "A": ;                                        // 整帧恒定
                "B": if (f >= 2 && x >= 320 && x <= 479 &&
                         y >= 160 && y <= 319) v = L_MOT;     // 160×160 区域变亮
                "C": if (f >= 1) v = L_BG + L_JUMP;           // 整帧亮度阶跃
                "D": if (f >= 2 && x >= 320 && x <= 327 &&
                         y >= 160 && y <= 167) v = L_MOT;     // 孤立**单个** 8×8 块
                "E": if ((f == 2 || f == 3) && x >= 320 && x <= 479 &&
                         y >= 160 && y <= 319) v = L_MOT;     // 先动（2~3 帧）后静
                // ★ F：静止的"垂直有结构"画面（上半亮、下半暗，水平分界 y=360）
                //   这是上板"静止也出框"的最小复现图案。
                "F": v = (y < 360) ? L_TOP : L_BOT;
                // ★ G：静止的多条水平带 + 垂直渐变（更接近真实室内画面）
                "G": v = band_g(y) + ((y * 24) / 720);
                // ★ H：静止底 + 噪声（幅度 ±N）
                "H": v = luma_noise(x, y, f);
                default: ;
            endcase
            luma = v;
        end
    endfunction

    // 一拍 4 像素 ⇒ 96 bit。字节序与 target_detect_96.v 的 TB 一致：
    //   p0=I_tdata[95:88] p1=[71:64] p2=[47:40] p3=[23:16]
    // ⚠ 本模块对一个块内 16 拍×4 像素**求和**，所以"哪个字节对哪个 x"不影响
    //   块亮度（4 个像素是同一组）；这里保持与 P5 相同的拼法以免两套 TB 混淆。
    function [95:0] make_word;
        input integer w0, f;
        reg [23:0] v0, v1, v2, v3;
        reg [7:0]  l0, l1, l2, l3;
        begin
            l0 = luma(w0,   cur_y, f); v0 = {l0, l0, l0};
            l1 = luma(w0+1, cur_y, f); v1 = {l1, l1, l1};
            l2 = luma(w0+2, cur_y, f); v2 = {l2, l2, l2};
            l3 = luma(w0+3, cur_y, f); v3 = {l3, l3, l3};
            make_word = {v3, v2, v1, v0};
        end
    endfunction

    // ---- 期望值（TB 侧的自检：判"解析上能一眼看出的量"）----
    //   精确数值（sigma-delta 多帧慢跟踪的具体块数）交给 Python 独立模型。
    task exp_frame;
        input  [7:0]  sc;
        input  integer f;
        output reg        v;
        output reg        g;
        output reg [13:0] raw, cnt;
        output reg [10:0] x0, x1;
        output reg [9:0]  y0, y1;
        begin
            v = 1'b0; g = 1'b0; raw = 14'd0; cnt = 14'd0;
            x0 = 11'd0; x1 = 11'd0; y0 = 10'd0; y1 = 10'd0;
            case (sc)
                "A": ;   // 全程静止
                "B": if (f >= 2) begin
                        v = 1'b1; raw = 14'd400; cnt = 14'd361;
                        x0 = 11'd328; x1 = 11'd479; y0 = 10'd168; y1 = 10'd319;
                     end
                // C：整帧阶跃 ⇒ 必须判全局突变、valid 必须为 0
                //    ★ 每块独立背景（本次修正后）：第 1 帧整帧偏离背景（diff=40>18）
                //      ⇒ 原始块数满额 14400 > 7200 ⇒ 全局突变 ✓ valid=0；
                //      腐蚀后 = 89×159 = 14151（块行 0 与块列 0 被 2×2 腐蚀吃掉）。
                //      之后背景以 **1 级/帧** 慢跟踪（BG_STEP=1），要 40 帧才追上
                //      ⇒ 本 TB 的 6 帧内每帧都是 raw=14400 / global=1 / valid=0 ✓。
                //    ⚠ 这正是"AE 一个台阶"的预期行为：宁可多报几帧"全局突变"，
                //      也绝不报成一个"运动目标"。
                "C": if (f >= 1) begin
                        v = 1'b0; g = 1'b1; raw = 14'd14400; cnt = 14'd14151;
                        x0 = 11'd8; x1 = 11'd1279; y0 = 10'd8; y1 = 10'd719;
                     end
                "D": if (f >= 2) begin
                        v = 1'b0; raw = 14'd1; cnt = 14'd0;   // 孤立块：腐蚀吃掉
                     end
                "E": if (f == 2 || f == 3) begin
                        v = 1'b1; raw = 14'd400; cnt = 14'd361;
                        x0 = 11'd328; x1 = 11'd479; y0 = 10'd168; y1 = 10'd319;
                     end
                // ★ F/G/H：**静止画面** ⇒ 每一帧都必须 valid=0、raw=0
                //    （这是上板事故的回归断言：静止出框就是这里挂）
                "F": ; "G": ; "H": ;
                default: ;
            endcase
        end
    endtask

    // ---- 落盘（交给 Python 逐帧核对）----
    integer      fd, frame_no = 0, fail_cnt = 0;
    reg [1023:0] out_name;
    initial begin
        if (!$value$plusargs("out=%s", out_name)) out_name = "motion_out.txt";
        fd = $fopen(out_name, "w");
        if (fd == 0) $display("  [WARN] cannot open %0s", out_name);
    end

    // ---- 逐帧采样与自检 ----
    //   ⚠ 采样时机：DUT 在**帧末那一拍**（帧的最后一个有效拍）用非阻塞赋值锁存
    //     O_*，所以本块在**下一拍**才看到稳定值（与 P5 的 TB 同一套约定）。
    reg        e_v, e_g;
    reg [13:0] e_raw, e_cnt;
    reg [10:0] e_x0, e_x1;
    reg [9:0]  e_y0, e_y1;
    always @(posedge clk) begin
        if (rst_n && O_frame_start) begin
            exp_frame(scene, frame_no, e_v, e_g, e_raw, e_cnt, e_x0, e_x1, e_y0, e_y1);
            $fwrite(fd, "%0d %0d %0d %0d %0d %0d %0d %0d %0d\n",
                    frame_no, O_valid, O_global_chg, O_motion_raw, O_blk_cnt,
                    O_x_min, O_x_max, O_y_min, O_y_max);
            $display("  [frame %0d] valid=%0d global=%0d raw=%0d blk=%0d bbox=(%0d,%0d)-(%0d,%0d)",
                     frame_no, O_valid, O_global_chg, O_motion_raw, O_blk_cnt,
                     O_x_min, O_y_min, O_x_max, O_y_max);
            if (O_valid !== e_v || O_global_chg !== e_g ||
                O_motion_raw !== e_raw || O_blk_cnt !== e_cnt ||
                O_x_min !== e_x0 || O_x_max !== e_x1 ||
                O_y_min !== e_y0 || O_y_max !== e_y1) begin
                fail_cnt = fail_cnt + 1;
                $display("      ** 与 TB 期望不符：期望 valid=%0d global=%0d raw=%0d blk=%0d bbox=(%0d,%0d)-(%0d,%0d)",
                         e_v, e_g, e_raw, e_cnt, e_x0, e_y0, e_x1, e_y1);
            end
            frame_no = frame_no + 1;
        end
    end

    integer ln, g, p, f;
    initial begin
        // ★ plusarg 必须在最前面读（跨 initial 竞争）
        plus_dummy = $value$plusargs("scene=%s", scene);
        plus_dummy = $value$plusargs("phase=%d", phase_off);
        plus_dummy = $value$plusargs("tuser=%d", tuser_on);
        plus_dummy = $value$plusargs("ctrl=%d",  ctrl_mode);
        plus_dummy = $value$plusargs("frames=%d", nfr);
        plus_dummy = $value$plusargs("noise=%d", noise_n);

        $display("");
        $display("============================================================");
        $display(" tb_motion_detect : scene=%0s  phase_off=%0d  tuser=%0d  ctrl=%0d  frames=%0d  noise=%0d",
                 scene, phase_off, tuser_on, ctrl_mode, nfr, noise_n);
        $display("------------------------------------------------------------");

        rst_n = 0;
        repeat (20) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // ---- ★ 相位偏移：先空转 phase_off 拍，这段**不发 tuser** ----
        //   内容用固定亮度，只为把自计时计数器推到帧中间；
        //   只有靠 tuser 对齐才能把相位纠正回来（+tuser=0 时就纠不回来 —— 对照组）。
        for (p = 0; p < phase_off; p = p + 1) begin
            @(negedge clk);
            I_tdata  = {24'h28_28_28, 24'h28_28_28, 24'h28_28_28, 24'h28_28_28};
            I_tvalid = 1'b1;
            I_tuser = 1'b0;
        end

        // ---- nfr 帧图案 ----
        for (f = 0; f < nfr; f = f + 1) begin
            for (ln = 0; ln < IMG_H; ln = ln + 1) begin
                cur_y = ln;
                for (g = 0; g < W_GRP; g = g + 1) begin
                    @(negedge clk);
                    I_tdata  = make_word(g*4, f);
                    I_tvalid = 1'b1;
                    // 帧首脉冲 = 每帧第 0 行第 0 拍（可关闭以做对照）
                    I_tuser  = tuser_on && (ln == 0) && (g == 0);
                end
            end
        end

        // ⚠ 本模块**帧末自结算**（结构由拍数推出，不依赖 tuser）⇒ 不需要像 P5 那样
        //   额外补一个 tuser 才能落盘，记录数应当正好 = nfr。
        @(negedge clk);
        I_tvalid = 1'b0; I_tuser = 1'b0; I_tdata = 96'd0;
        repeat (20) @(posedge clk);
        $fclose(fd);

        $display("------------------------------------------------------------");
        $display(" 共输出 %0d 帧结果（期望 %0d 帧）", frame_no, nfr);
        $display(" 逐帧结果已写入，请用 Python 独立核对：");
        $display("     python tools\\check_motion_detect.py --scene %0s --out <落盘文件>", scene);
        $display("============================================================");
        if (frame_no != nfr)
            $display("==== FAIL ====  (帧数不符：%0d != %0d)", frame_no, nfr);
        else if (fail_cnt == 0)
            $display("==== PASS ====");
        else if (ctrl_mode != 0)
            $display("==== CTRL ====  (对照组：%0d 帧与期望不同，这是相位未对齐的预期表现)", fail_cnt);
        else
            $display("==== FAIL ====  (%0d 帧与期望不符)", fail_cnt);
        $finish;
    end

    initial begin
        #400_000_000;                     // 12 帧 ≈ 5.5 ms 仿真时间，400 ms 上限足够
        $display(" [NG] timeout");
        $finish;
    end

endmodule
