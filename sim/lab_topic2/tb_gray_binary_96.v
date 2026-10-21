// ============================================================================
//  tb_gray_binary_96.v  --  lab_topic2_basic / isp/gray_binary_96.v 的自检 TB
//
//  被测：gray_binary_96（96bit = 4×RGB888，mode 0/1/2/3，阈值可调）
//
//  验证内容
//    T0  复位：输出全 0、tvalid/tlast/tuser 均为 0
//    T1  mode=0 原图直通：O_tdata 逐字节等于 I_tdata（仅延迟 1 拍）
//    T2  mode=1 灰度：Y=(77R+150G+29B)>>8，R=G=B=Y
//    T3  mode=2 二值化：Y > th ? FF : 00，且 R=G=B
//    T4  mode=3 反色：~R ~G ~B
//    T5  阈值边界：th=255 时 Y=255 应输出 00（严格 > 比较）
//    T6  控制信号对齐：tlast/tuser 随数据同拍延迟
//    T7  tready 直通：O_tready === I_tready（组合）
//    T8  像素位置独立：改动单个像素不影响其它 3 个
//    T9  背靠背 4 拍：tvalid 连续、停止后归 0
//
//  时序要点（本 TB 的关键设计）：
//    DUT 内部 I_mode/I_threshold 是**组合**参与 pixel_proc，随后与数据一起被
//    r_tdata 打一拍。所以信号必须在**同一个 posedge 之前**同时稳定，
//    否则 mode 会比数据多延迟一拍、造成错位。本 TB 用 t_settle 保证这一点。
//
//  运行：vlib work ; vlog gray_binary_96.v tb_gray_binary_96.v ; vsim -c -batch -lib work tb_gray_binary_96 -do "run -all; quit -f"
// ============================================================================
`timescale 1ns/1ps

module tb_gray_binary_96;

    reg         clk   = 0;
    reg         rst_n = 0;

    reg         I_tlast  = 0;
    reg         I_tuser  = 0;
    reg  [95:0] I_tdata  = 96'd0;
    reg         I_tvalid = 0;
    reg         I_tready = 1;

    reg  [1:0]  I_mode      = 2'b00;
    reg  [7:0]  I_threshold = 8'd128;

    wire        O_tlast, O_tuser, O_tvalid, O_tready;
    wire [95:0] O_tdata;

    gray_binary_96 #(.IMG_WIDTH(1024), .IMG_HEIGHT(600)) dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_tlast(I_tlast), .I_tuser(I_tuser),
        .I_tdata(I_tdata), .I_tvalid(I_tvalid), .I_tready(I_tready),
        .I_mode(I_mode), .I_threshold(I_threshold),
        .O_tlast(O_tlast), .O_tuser(O_tuser),
        .O_tdata(O_tdata), .O_tvalid(O_tvalid), .O_tready(O_tready)
    );

    always #5 clk = ~clk;          // 100 MHz

    // ---- 记分板 ----
    integer errors = 0;
    integer checks = 0;
    integer i, k;

    reg [7:0] exp_bytes [0:11];    // 顺序：px0r,px0g,px0b, px1r,..., px3b
    reg [7:0] got_bytes [0:11];

    // 单像素期望值计算（先定义，供 calc_expect 使用）
    reg [7:0] rr, gg, bb, yy;
    task calc1;
        input integer idx;
        input [7:0]  r, g, b;
        input [1:0]  mode;
        input [7:0]  th;
        begin
            rr = r; gg = g; bb = b;
            yy = ((r * 77) + (g * 150) + (b * 29)) >> 8;
            case (mode)
                2'b00: begin exp_bytes[3*idx+0]=r;  exp_bytes[3*idx+1]=g;  exp_bytes[3*idx+2]=b;  end
                2'b01: begin exp_bytes[3*idx+0]=yy; exp_bytes[3*idx+1]=yy; exp_bytes[3*idx+2]=yy; end
                2'b10: begin
                           exp_bytes[3*idx+0] = (yy > th) ? 8'hFF : 8'h00;
                           exp_bytes[3*idx+1] = (yy > th) ? 8'hFF : 8'h00;
                           exp_bytes[3*idx+2] = (yy > th) ? 8'hFF : 8'h00;
                       end
                2'b11: begin exp_bytes[3*idx+0]=~r; exp_bytes[3*idx+1]=~g; exp_bytes[3*idx+2]=~b; end
            endcase
        end
    endtask

    task calc_expect;
        input [1:0] mode;
        input [7:0] th;
        begin
            calc1(0, I_tdata[95:88], I_tdata[87:80], I_tdata[79:72], mode, th);
            calc1(1, I_tdata[71:64], I_tdata[63:56], I_tdata[55:48], mode, th);
            calc1(2, I_tdata[47:40], I_tdata[39:32], I_tdata[31:24], mode, th);
            calc1(3, I_tdata[23:16], I_tdata[15:8],  I_tdata[7:0],   mode, th);
        end
    endtask

    task latch_got;
        begin
            for (i = 0; i < 4; i = i + 1) begin
                got_bytes[3*i+0] = O_tdata[95-24*i -: 8];
                got_bytes[3*i+1] = O_tdata[87-24*i -: 8];
                got_bytes[3*i+2] = O_tdata[79-24*i -: 8];
            end
        end
    endtask

    task assert_chk;
        input [8*48:1] name;
        input          cond;
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("  [FAIL] %0s", name);
            end
        end
    endtask

    // 先让 mode/threshold 稳定（它们参与组合逻辑），再驱动数据
    task t_settle;
        input [1:0] mode;
        input [7:0] th;
        begin
            I_mode      = mode;
            I_threshold = th;
            I_tvalid    = 1'b0;
            @(posedge clk);       // mode/th 此时被组合逻辑采用；无数据
        end
    endtask

    // 驱动一拍数据并比对（输出延迟 1 拍）
    task drive_and_compare;
        input [3:0]  tid;
        input [1:0]  mode;
        input [7:0]  th;
        input        tlast;
        input        tuser;
        reg          mismatch;
        reg [95:0]   exp_vec;
        begin
            t_settle(mode, th);
            // 现在设置数据 + valid，下一个 posedge 被采样
            I_tlast  = tlast;
            I_tuser  = tuser;
            I_tvalid = 1'b1;
            @(posedge clk);       // 采样输入
            calc_expect(mode, th);
            @(negedge clk);       // 输出已更新（1 拍延迟）
            latch_got;
            mismatch = 0;
            for (k = 0; k < 12; k = k + 1)
                if (got_bytes[k] !== exp_bytes[k]) mismatch = 1;
            exp_vec = {exp_bytes[0],exp_bytes[1],exp_bytes[2],exp_bytes[3],
                       exp_bytes[4],exp_bytes[5],exp_bytes[6],exp_bytes[7],
                       exp_bytes[8],exp_bytes[9],exp_bytes[10],exp_bytes[11]};
            checks = checks + 1;
            if (mismatch) begin
                errors = errors + 1;
                $display("  [FAIL] T%0d mode=%0d th=%3d", tid, mode, th);
                $display("         输入 = 96'h%024h", I_tdata);
                $display("         期望 = 96'h%024h", exp_vec);
                $display("         实得 = 96'h%024h", O_tdata);
            end else begin
                $display("  [ ok ] T%0d mode=%0d th=%3d  96'h%024h", tid, mode, th, O_tdata);
            end
            // 控制信号必须与数据同拍
            checks = checks + 1;
            if (O_tlast !== tlast || O_tuser !== tuser || O_tvalid !== 1'b1) begin
                errors = errors + 1;
                $display("  [FAIL] T%0d 控制信号错位: O_tlast=%b(exp %b) O_tuser=%b(exp %b) O_tvalid=%b(exp 1)",
                         tid, O_tlast, tlast, O_tuser, tuser, O_tvalid);
            end
            I_tvalid = 1'b0;
            I_tlast  = 1'b0;
            I_tuser  = 1'b0;
            @(posedge clk);
        end
    endtask

    // px0=RED, px1=GREEN, px2=BLUE, px3=WHITE
    localparam [95:0] VEC_RGBW =
        {8'hFF,8'h00,8'h00,   8'h00,8'hFF,8'h00,   8'h00,8'h00,8'hFF,   8'hFF,8'hFF,8'hFF};
    localparam [95:0] VEC_ALLFF =
        {8'hFF,8'hFF,8'hFF,   8'hFF,8'hFF,8'hFF,   8'hFF,8'hFF,8'hFF,   8'hFF,8'hFF,8'hFF};

    integer n;

    // T9 输出侧统计（时间无关：统计整个窗口内 tvalid/tlast/tuser 的高拍数）
    reg       t9_watch   = 1'b0;
    integer   o_valid_cnt = 0;
    integer   o_last_cnt  = 0;
    integer   o_user_cnt  = 0;

    always @(negedge clk) begin
        if (t9_watch) begin
            if (O_tvalid === 1'b1) o_valid_cnt = o_valid_cnt + 1;
            if (O_tvalid === 1'b1 && O_tlast === 1'b1) o_last_cnt = o_last_cnt + 1;
            if (O_tvalid === 1'b1 && O_tuser === 1'b1) o_user_cnt = o_user_cnt + 1;
        end
    end

    initial begin
        $display("============================================================");
        $display(" tb_gray_binary_96  --  自检开始");
        $display("============================================================");

        // ---------- T0 复位 ----------
        rst_n = 0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        checks = checks + 4;
        if (O_tdata !== 96'd0)   begin errors=errors+1; $display("  [FAIL] T0 O_tdata!=0");   end
        if (O_tvalid !== 1'b0)   begin errors=errors+1; $display("  [FAIL] T0 O_tvalid!=0");  end
        if (O_tlast !== 1'b0)    begin errors=errors+1; $display("  [FAIL] T0 O_tlast!=0");   end
        if (O_tuser !== 1'b0)    begin errors=errors+1; $display("  [FAIL] T0 O_tuser!=0");   end
        if (errors == 0) $display("  [ ok ] T0 复位状态全 0");
        rst_n = 1;
        @(posedge clk);

        // ---------- T1 原图 ----------
        I_tdata = VEC_RGBW;  drive_and_compare(1, 2'b00, 8'd128, 1'b1, 1'b1);
        // ---------- T2 灰度 ----------
        I_tdata = VEC_RGBW;  drive_and_compare(2, 2'b01, 8'd128, 1'b0, 1'b0);
        // ---------- T3 二值化 ----------
        I_tdata = VEC_RGBW;  drive_and_compare(3, 2'b10, 8'd128, 1'b0, 1'b0);
        // ---------- T4 反色 ----------
        I_tdata = VEC_RGBW;  drive_and_compare(4, 2'b11, 8'd128, 1'b0, 1'b0);

        // ---------- T5 阈值边界 ----------
        I_tdata = VEC_ALLFF; drive_and_compare(5, 2'b10, 8'd254, 1'b0, 1'b0);  // Y=255>254 -> FF
        I_tdata = VEC_ALLFF; drive_and_compare(5, 2'b10, 8'd255, 1'b0, 1'b0);  // Y=255>255 假 -> 00
        I_tdata = 96'd0;     drive_and_compare(5, 2'b10, 8'd0,   1'b0, 1'b0);  // Y=0>0   假 -> 00
        I_tdata = 96'd0;     drive_and_compare(5, 2'b10, 8'd255, 1'b0, 1'b0);  // 00

        // ---------- T7 tready 直通 ----------
        I_tready = 1'b0; #1;
        checks=checks+1; if (O_tready !== 1'b0) begin errors=errors+1; $display("  [FAIL] T7 tready=0 未直通"); end
        I_tready = 1'b1; #1;
        checks=checks+1; if (O_tready !== 1'b1) begin errors=errors+1; $display("  [FAIL] T7 tready=1 未直通"); end
        if (errors == 0) $display("  [ ok ] T7 O_tready 直通 I_tready");

        // ---------- T8 像素位置独立 ----------
        I_tdata = {8'h11,8'h22,8'h33, 8'h44,8'h55,8'h66, 8'h77,8'h5A,8'h99, 8'hAA,8'hBB,8'hCC};
        drive_and_compare(8, 2'b00, 8'd128, 1'b0, 1'b0);
        I_tdata = {8'h11,8'h22,8'h33, 8'h44,8'h55,8'h66, 8'h77,8'h5A,8'h99, 8'hAA,8'hBB,8'hCC};
        drive_and_compare(8, 2'b01, 8'd100, 1'b0, 1'b0);

        // ---------- T9 背靠背 4 拍 ----------
        // 用时间无关的方法：在输入侧连打 4 拍，同时统计输出侧 tvalid 的高拍数。
        // 输出比输入晚 1 拍，所以从驱动开始到排空应恰好有 4 拍 tvalid=1。
        $display("  --- T9 背靠背 4 拍 ---");
        t_settle(2'b01, 8'd128);
        o_valid_cnt = 0; o_last_cnt = 0; o_user_cnt = 0; t9_watch = 1'b1;
        for (n = 0; n < 4; n = n + 1) begin
            I_tdata  = VEC_RGBW;
            I_tlast  = (n == 3);
            I_tuser  = (n == 0);
            I_tvalid = 1'b1;
            @(posedge clk);
        end
        I_tvalid = 1'b0; I_tlast = 1'b0; I_tuser = 1'b0;
        repeat (4) @(posedge clk);      // 等流水排空
        t9_watch = 1'b0;
        checks = checks + 1;
        if (o_valid_cnt !== 4) begin
            errors = errors + 1;
            $display("  [FAIL] T9 期望 4 拍 tvalid，实得 %0d 拍", o_valid_cnt);
        end else
            $display("  [ ok ] T9 背靠背 4 拍 tvalid 恰好 4 拍");
        checks = checks + 1;
        if (o_last_cnt !== 1) begin
            errors = errors + 1;
            $display("  [FAIL] T9 期望 1 个 tlast，实得 %0d", o_last_cnt);
        end else
            $display("  [ ok ] T9 tlast 恰好 1 拍（末拍对齐）");
        checks = checks + 1;
        if (o_user_cnt !== 1) begin
            errors = errors + 1;
            $display("  [FAIL] T9 期望 1 个 tuser，实得 %0d", o_user_cnt);
        end else
            $display("  [ ok ] T9 tuser 恰好 1 拍（首拍对齐）");

        @(negedge clk);
        checks = checks + 1;
        if (O_tvalid !== 1'b0) begin errors=errors+1; $display("  [FAIL] T9 停止后 tvalid 未归 0"); end
        else $display("  [ ok ] T9 输入停止后 tvalid 归 0");

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
        #500000;
        $display("  [FAIL] 仿真超时");
        $finish;
    end

endmodule
