//=============================================================
// gray_binary_96.v  ——  lab4 专用版本（★ 常量乘法改移位加法）
//
// 来源：lab_topic2_basic/user_source/hdl_source/isp/gray_binary_96.v
//       （原版 md5 DE0170AAB6344CFDE2C86AF74095B55F，仅改本文件）
//
// 与 lab_topic2 原版的**唯一区别**：灰度加权和的常量乘法改成移位加法。
//
// 为什么改
// --------
// 原版写 `R*77 + G*150 + B*29`，综合器把 12 个常量乘法全映射到 DSP
// （u_gray_binary_96 实测 12 DSP）—— 本机实测：全设计 DSP 从 8 涨到 20（50%）。
// 而方案里明确规定「**常量乘法绝不能用 DSP**」
// （见 doc/analysis/赛题二-文件全量分析与方案建议.md §0.5-L2 与风险 R13：
//   DSP 只有 40 个，4px/拍 × 3 通道的常量系数一律用 CSD 移位-加法）。
//
// 数学等价性（严格等式，非近似）
// ------------------------------
// 77  = 1001101₂  = 64 + 8 + 4 + 1
//    -> (r<<6) + (r<<3) + (r<<2) + r          位权和 64+8+4+1 = 77   ✓
// 150 = 10010110₂ = 128 + 16 + 4 + 2
//    -> (g<<7) + (g<<4) + (g<<2) + (g<<1)     位权和 128+16+4+2 = 150 ✓
// 29  = 11101₂    = 32 − 2 − 1
//    -> (b<<5) − (b<<1) − b                   位权和 32−2−1 = 29     ✓
//
// 对任意 8 位输入，移位加法与原乘法**逐位等价**（和位宽同为 16 位）。
// 功能仿真已用 58 项检查覆盖（含 4 个模式、阈值边界、背靠背吞吐）。
//
// 端口与行为与 lab_topic2 原版完全一致：同样的 4 模式、同样的输出打一拍。
//=============================================================
`timescale 1ns/1ps

module gray_binary_96 #(
    parameter IMG_WIDTH  = 1024,
    parameter IMG_HEIGHT = 600
)(
    input  wire        I_clk,
    input  wire        I_rst_n,

    input  wire        I_tlast,
    input  wire        I_tuser,
    input  wire [95:0] I_tdata,
    input  wire        I_tvalid,
    input  wire        I_tready,

    input  wire [1:0]  I_mode,       // 0=原图 1=灰度 2=二值化 3=反色
    input  wire [7:0]  I_threshold,  // 二值化阈值

    output wire        O_tlast,
    output wire        O_tuser,
    output wire [95:0] O_tdata,
    output wire        O_tvalid,
    output wire        O_tready
);

    // 控制信号（随数据一起打一拍，保持对齐）
    reg         r_tvalid;
    reg         r_tlast;
    reg         r_tuser;
    reg  [95:0] r_tdata;

    assign O_tvalid = r_tvalid;
    assign O_tlast  = r_tlast;
    assign O_tuser  = r_tuser;
    assign O_tready = I_tready;   // 视频流无反压，直通
    assign O_tdata  = r_tdata;

    // 拆出4个像素（与 edge_detect_96 的 pix0=[95:72]..pix3=[23:0] 完全一致）
    wire [7:0] px0_r = I_tdata[95:88];
    wire [7:0] px0_g = I_tdata[87:80];
    wire [7:0] px0_b = I_tdata[79:72];

    wire [7:0] px1_r = I_tdata[71:64];
    wire [7:0] px1_g = I_tdata[63:56];
    wire [7:0] px1_b = I_tdata[55:48];

    wire [7:0] px2_r = I_tdata[47:40];
    wire [7:0] px2_g = I_tdata[39:32];
    wire [7:0] px2_b = I_tdata[31:24];

    wire [7:0] px3_r = I_tdata[23:16];
    wire [7:0] px3_g = I_tdata[15:8];
    wire [7:0] px3_b = I_tdata[7:0];

    // ------------------------------------------------------------------
    // 灰度加权和：Y = (R*77 + G*150 + B*29) >> 8
    //   77+150+29 = 256，对应 0.299/0.587/0.114
    //   ★ 全部用移位加法，**不产生任何 DSP**
    //     注意：移位前先扩展到 16 位，否则 (r<<6)+(r<<3) 会溢出 8 位
    // ------------------------------------------------------------------
    function [15:0] gray_sum;
        input [7:0] r;
        input [7:0] g;
        input [7:0] b;
        reg   [15:0] r16, g16, b16;
        begin
            r16 = {8'd0, r};
            g16 = {8'd0, g};
            b16 = {8'd0, b};
            gray_sum = ( (r16 << 6) + (r16 << 3) + (r16 << 2) + r16 )
                     + ( (g16 << 7) + (g16 << 4) + (g16 << 2) + (g16 << 1) )
                     + ( (b16 << 5) - (b16 << 1) - b16 );
        end
    endfunction

    wire [15:0] y0_sum = gray_sum(px0_r, px0_g, px0_b);
    wire [15:0] y1_sum = gray_sum(px1_r, px1_g, px1_b);
    wire [15:0] y2_sum = gray_sum(px2_r, px2_g, px2_b);
    wire [15:0] y3_sum = gray_sum(px3_r, px3_g, px3_b);

    wire [7:0] y0 = y0_sum[15:8];
    wire [7:0] y1 = y1_sum[15:8];
    wire [7:0] y2 = y2_sum[15:8];
    wire [7:0] y3 = y3_sum[15:8];

    // 每个像素的输出（24bit RGB）
    function [23:0] pixel_proc;
        input [7:0] r, g, b, y;
        input [1:0] mode;
        input [7:0] th;
        reg [7:0] ro, go, bo;
        begin
            case (mode)
                2'b00: begin ro = r;          go = g;          bo = b;          end  // 原图
                2'b01: begin ro = y;          go = y;          bo = y;          end  // 灰度
                2'b10: begin ro = (y > th) ? 8'hFF : 8'h00;
                             go = (y > th) ? 8'hFF : 8'h00;
                             bo = (y > th) ? 8'hFF : 8'h00;                    end  // 二值化
                2'b11: begin ro = ~r;         go = ~g;         bo = ~b;         end  // 反色
            endcase
            pixel_proc = {ro, go, bo};
        end
    endfunction

    wire [23:0] out0 = pixel_proc(px0_r, px0_g, px0_b, y0, I_mode, I_threshold);
    wire [23:0] out1 = pixel_proc(px1_r, px1_g, px1_b, y1, I_mode, I_threshold);
    wire [23:0] out2 = pixel_proc(px2_r, px2_g, px2_b, y2, I_mode, I_threshold);
    wire [23:0] out3 = pixel_proc(px3_r, px3_g, px3_b, y3, I_mode, I_threshold);

    // 输出打一拍：把 加减法的组合逻辑关断在寄存器之间，保证时序
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            r_tdata  <= 96'd0;
            r_tvalid <= 1'b0;
            r_tlast  <= 1'b0;
            r_tuser  <= 1'b0;
        end else begin
            r_tdata  <= {out0, out1, out2, out3};
            r_tvalid <= I_tvalid;
            r_tlast  <= I_tlast;
            r_tuser  <= I_tuser;
        end
    end

endmodule
