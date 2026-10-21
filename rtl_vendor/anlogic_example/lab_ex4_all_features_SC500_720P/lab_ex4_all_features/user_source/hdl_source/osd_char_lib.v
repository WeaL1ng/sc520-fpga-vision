// ============================================================================
//  osd_char_lib.v  ---  OSD 字符点阵库（8x16）
// ----------------------------------------------------------------------------
//  ⚠ 本文件由 tools/gen_osd_char_lib.py **自动生成，请勿手工修改**
//
//  字形约定（实测自原始文件）：
//    * 点阵 8 宽 x 16 高；**有效内容为 row 0..10（11 行）**，row 11..15 全 0
//    * 每行 16 bit，**MSB(bit15) 是最左列**
//    * 最大有效列宽 14
//
//  字符集：
//    0x20 空格 | 0x25 '%' | 0x2D '-' | 0x2E '.' | 0x2F '/'
//    0x30-0x39 数字 0-9 | 0x3A ':'
//    0x41-0x5A 大写 A-Z
//    0x61-0x7A 小写 a-z      <- P3 新增（用于 'ms' 等）
//    0x80 中文'安' | 0x81 中文'路'   <- 原始图形字形，逐位保留
//
//  原有 39 个字形与旧版**逐位相同**（生成器已校验解析数量一致）
// ============================================================================

module osd_char_lib (
    input  wire [7:0]  I_char,
    input  wire [3:0]  I_row,
    output reg  [15:0] O_row_bits
);

    localparam CHAR_SP            = 8'h20;
    localparam CHAR_PCT           = 8'h25;
    localparam CHAR_LPAREN        = 8'h28;
    localparam CHAR_RPAREN        = 8'h29;
    localparam CHAR_PLUS          = 8'h2b;
    localparam CHAR_COMMA         = 8'h2c;
    localparam CHAR_MINUS         = 8'h2d;
    localparam CHAR_DOT           = 8'h2e;
    localparam CHAR_SLASH         = 8'h2f;
    localparam CHAR_0             = 8'h30;
    localparam CHAR_1             = 8'h31;
    localparam CHAR_2             = 8'h32;
    localparam CHAR_3             = 8'h33;
    localparam CHAR_4             = 8'h34;
    localparam CHAR_5             = 8'h35;
    localparam CHAR_6             = 8'h36;
    localparam CHAR_7             = 8'h37;
    localparam CHAR_8             = 8'h38;
    localparam CHAR_9             = 8'h39;
    localparam CHAR_COLON         = 8'h3a;
    localparam CHAR_LT            = 8'h3c;
    localparam CHAR_EQ            = 8'h3d;
    localparam CHAR_GT            = 8'h3e;
    localparam CHAR_A             = 8'h41;
    localparam CHAR_B             = 8'h42;
    localparam CHAR_C             = 8'h43;
    localparam CHAR_D             = 8'h44;
    localparam CHAR_E             = 8'h45;
    localparam CHAR_F             = 8'h46;
    localparam CHAR_G             = 8'h47;
    localparam CHAR_H             = 8'h48;
    localparam CHAR_I             = 8'h49;
    localparam CHAR_J             = 8'h4a;
    localparam CHAR_K             = 8'h4b;
    localparam CHAR_L             = 8'h4c;
    localparam CHAR_M             = 8'h4d;
    localparam CHAR_N             = 8'h4e;
    localparam CHAR_O             = 8'h4f;
    localparam CHAR_P             = 8'h50;
    localparam CHAR_Q             = 8'h51;
    localparam CHAR_R             = 8'h52;
    localparam CHAR_S             = 8'h53;
    localparam CHAR_T             = 8'h54;
    localparam CHAR_U             = 8'h55;
    localparam CHAR_V             = 8'h56;
    localparam CHAR_W             = 8'h57;
    localparam CHAR_X             = 8'h58;
    localparam CHAR_Y             = 8'h59;
    localparam CHAR_Z             = 8'h5a;
    localparam CHAR_LOW_A         = 8'h61;
    localparam CHAR_LOW_B         = 8'h62;
    localparam CHAR_LOW_C         = 8'h63;
    localparam CHAR_LOW_D         = 8'h64;
    localparam CHAR_LOW_E         = 8'h65;
    localparam CHAR_LOW_F         = 8'h66;
    localparam CHAR_LOW_G         = 8'h67;
    localparam CHAR_LOW_H         = 8'h68;
    localparam CHAR_LOW_I         = 8'h69;
    localparam CHAR_LOW_J         = 8'h6a;
    localparam CHAR_LOW_K         = 8'h6b;
    localparam CHAR_LOW_L         = 8'h6c;
    localparam CHAR_LOW_M         = 8'h6d;
    localparam CHAR_LOW_N         = 8'h6e;
    localparam CHAR_LOW_O         = 8'h6f;
    localparam CHAR_LOW_P         = 8'h70;
    localparam CHAR_LOW_Q         = 8'h71;
    localparam CHAR_LOW_R         = 8'h72;
    localparam CHAR_LOW_S         = 8'h73;
    localparam CHAR_LOW_T         = 8'h74;
    localparam CHAR_LOW_U         = 8'h75;
    localparam CHAR_LOW_V         = 8'h76;
    localparam CHAR_LOW_W         = 8'h77;
    localparam CHAR_LOW_X         = 8'h78;
    localparam CHAR_LOW_Y         = 8'h79;
    localparam CHAR_LOW_Z         = 8'h7a;
    localparam CHAR_AN            = 8'h80;
    localparam CHAR_LU            = 8'h81;

    always @(*) begin
        case (I_char)
            CHAR_SP: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0000;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'h0000;
                    4'd5 : O_row_bits = 16'h0000;
                    4'd6 : O_row_bits = 16'h0000;
                    4'd7 : O_row_bits = 16'h0000;
                    4'd8 : O_row_bits = 16'h0000;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_PCT: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h6200;
                    4'd3 : O_row_bits = 16'h6400;
                    4'd4 : O_row_bits = 16'h0800;
                    4'd5 : O_row_bits = 16'h1000;
                    4'd6 : O_row_bits = 16'h2000;
                    4'd7 : O_row_bits = 16'h4600;
                    4'd8 : O_row_bits = 16'h8600;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LPAREN: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h1000;
                    4'd3 : O_row_bits = 16'h2000;
                    4'd4 : O_row_bits = 16'h4000;
                    4'd5 : O_row_bits = 16'h4000;
                    4'd6 : O_row_bits = 16'h4000;
                    4'd7 : O_row_bits = 16'h4000;
                    4'd8 : O_row_bits = 16'h2000;
                    4'd9 : O_row_bits = 16'h1000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_RPAREN: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h1000;
                    4'd3 : O_row_bits = 16'h0800;
                    4'd4 : O_row_bits = 16'h0400;
                    4'd5 : O_row_bits = 16'h0400;
                    4'd6 : O_row_bits = 16'h0400;
                    4'd7 : O_row_bits = 16'h0400;
                    4'd8 : O_row_bits = 16'h0800;
                    4'd9 : O_row_bits = 16'h1000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_PLUS: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0000;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'h1000;
                    4'd5 : O_row_bits = 16'h1000;
                    4'd6 : O_row_bits = 16'h7c00;
                    4'd7 : O_row_bits = 16'h1000;
                    4'd8 : O_row_bits = 16'h1000;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_COMMA: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0000;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'h0000;
                    4'd5 : O_row_bits = 16'h0000;
                    4'd6 : O_row_bits = 16'h0000;
                    4'd7 : O_row_bits = 16'h1000;
                    4'd8 : O_row_bits = 16'h1000;
                    4'd9 : O_row_bits = 16'h2000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_MINUS: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0000;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'h0000;
                    4'd5 : O_row_bits = 16'h3e00;
                    4'd6 : O_row_bits = 16'h0000;
                    4'd7 : O_row_bits = 16'h0000;
                    4'd8 : O_row_bits = 16'h0000;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_DOT: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0000;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'h0000;
                    4'd5 : O_row_bits = 16'h0000;
                    4'd6 : O_row_bits = 16'h0000;
                    4'd7 : O_row_bits = 16'h0000;
                    4'd8 : O_row_bits = 16'h2000;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_SLASH: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0200;
                    4'd3 : O_row_bits = 16'h0200;
                    4'd4 : O_row_bits = 16'h0400;
                    4'd5 : O_row_bits = 16'h0800;
                    4'd6 : O_row_bits = 16'h1000;
                    4'd7 : O_row_bits = 16'h2000;
                    4'd8 : O_row_bits = 16'h4000;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_0: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h1ff8;
                    4'd2 : O_row_bits = 16'h1ff8;
                    4'd3 : O_row_bits = 16'h300c;
                    4'd4 : O_row_bits = 16'h300c;
                    4'd5 : O_row_bits = 16'h300c;
                    4'd6 : O_row_bits = 16'h0000;
                    4'd7 : O_row_bits = 16'h0000;
                    4'd8 : O_row_bits = 16'h300c;
                    4'd9 : O_row_bits = 16'h300c;
                    4'd10: O_row_bits = 16'h300c;
                    4'd11: O_row_bits = 16'h1ff8;
                    4'd12: O_row_bits = 16'h1ff8;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_1: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h000c;
                    4'd2 : O_row_bits = 16'h000c;
                    4'd3 : O_row_bits = 16'h000c;
                    4'd4 : O_row_bits = 16'h000c;
                    4'd5 : O_row_bits = 16'h000c;
                    4'd6 : O_row_bits = 16'h0000;
                    4'd7 : O_row_bits = 16'h0000;
                    4'd8 : O_row_bits = 16'h000c;
                    4'd9 : O_row_bits = 16'h000c;
                    4'd10: O_row_bits = 16'h000c;
                    4'd11: O_row_bits = 16'h000c;
                    4'd12: O_row_bits = 16'h000c;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_2: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h1ff8;
                    4'd2 : O_row_bits = 16'h1ff8;
                    4'd3 : O_row_bits = 16'h000c;
                    4'd4 : O_row_bits = 16'h000c;
                    4'd5 : O_row_bits = 16'h000c;
                    4'd6 : O_row_bits = 16'h1ff8;
                    4'd7 : O_row_bits = 16'h1ff8;
                    4'd8 : O_row_bits = 16'h3000;
                    4'd9 : O_row_bits = 16'h3000;
                    4'd10: O_row_bits = 16'h3000;
                    4'd11: O_row_bits = 16'h1ff8;
                    4'd12: O_row_bits = 16'h1ff8;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_3: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h1ff8;
                    4'd2 : O_row_bits = 16'h1ff8;
                    4'd3 : O_row_bits = 16'h000c;
                    4'd4 : O_row_bits = 16'h000c;
                    4'd5 : O_row_bits = 16'h000c;
                    4'd6 : O_row_bits = 16'h1ff8;
                    4'd7 : O_row_bits = 16'h1ff8;
                    4'd8 : O_row_bits = 16'h000c;
                    4'd9 : O_row_bits = 16'h000c;
                    4'd10: O_row_bits = 16'h000c;
                    4'd11: O_row_bits = 16'h1ff8;
                    4'd12: O_row_bits = 16'h1ff8;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_4: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h300c;
                    4'd2 : O_row_bits = 16'h300c;
                    4'd3 : O_row_bits = 16'h300c;
                    4'd4 : O_row_bits = 16'h300c;
                    4'd5 : O_row_bits = 16'h300c;
                    4'd6 : O_row_bits = 16'h1ff8;
                    4'd7 : O_row_bits = 16'h1ff8;
                    4'd8 : O_row_bits = 16'h000c;
                    4'd9 : O_row_bits = 16'h000c;
                    4'd10: O_row_bits = 16'h000c;
                    4'd11: O_row_bits = 16'h000c;
                    4'd12: O_row_bits = 16'h000c;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_5: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h1ff8;
                    4'd2 : O_row_bits = 16'h1ff8;
                    4'd3 : O_row_bits = 16'h3000;
                    4'd4 : O_row_bits = 16'h3000;
                    4'd5 : O_row_bits = 16'h3000;
                    4'd6 : O_row_bits = 16'h1ff8;
                    4'd7 : O_row_bits = 16'h1ff8;
                    4'd8 : O_row_bits = 16'h000c;
                    4'd9 : O_row_bits = 16'h000c;
                    4'd10: O_row_bits = 16'h000c;
                    4'd11: O_row_bits = 16'h1ff8;
                    4'd12: O_row_bits = 16'h1ff8;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_6: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h1ff8;
                    4'd2 : O_row_bits = 16'h1ff8;
                    4'd3 : O_row_bits = 16'h3000;
                    4'd4 : O_row_bits = 16'h3000;
                    4'd5 : O_row_bits = 16'h3000;
                    4'd6 : O_row_bits = 16'h1ff8;
                    4'd7 : O_row_bits = 16'h1ff8;
                    4'd8 : O_row_bits = 16'h300c;
                    4'd9 : O_row_bits = 16'h300c;
                    4'd10: O_row_bits = 16'h300c;
                    4'd11: O_row_bits = 16'h1ff8;
                    4'd12: O_row_bits = 16'h1ff8;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_7: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h1ff8;
                    4'd2 : O_row_bits = 16'h1ff8;
                    4'd3 : O_row_bits = 16'h000c;
                    4'd4 : O_row_bits = 16'h000c;
                    4'd5 : O_row_bits = 16'h000c;
                    4'd6 : O_row_bits = 16'h0000;
                    4'd7 : O_row_bits = 16'h0000;
                    4'd8 : O_row_bits = 16'h000c;
                    4'd9 : O_row_bits = 16'h000c;
                    4'd10: O_row_bits = 16'h000c;
                    4'd11: O_row_bits = 16'h000c;
                    4'd12: O_row_bits = 16'h000c;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_8: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h1ff8;
                    4'd2 : O_row_bits = 16'h1ff8;
                    4'd3 : O_row_bits = 16'h300c;
                    4'd4 : O_row_bits = 16'h300c;
                    4'd5 : O_row_bits = 16'h300c;
                    4'd6 : O_row_bits = 16'h1ff8;
                    4'd7 : O_row_bits = 16'h1ff8;
                    4'd8 : O_row_bits = 16'h300c;
                    4'd9 : O_row_bits = 16'h300c;
                    4'd10: O_row_bits = 16'h300c;
                    4'd11: O_row_bits = 16'h1ff8;
                    4'd12: O_row_bits = 16'h1ff8;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_9: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h1ff8;
                    4'd2 : O_row_bits = 16'h1ff8;
                    4'd3 : O_row_bits = 16'h300c;
                    4'd4 : O_row_bits = 16'h300c;
                    4'd5 : O_row_bits = 16'h300c;
                    4'd6 : O_row_bits = 16'h1ff8;
                    4'd7 : O_row_bits = 16'h1ff8;
                    4'd8 : O_row_bits = 16'h000c;
                    4'd9 : O_row_bits = 16'h000c;
                    4'd10: O_row_bits = 16'h000c;
                    4'd11: O_row_bits = 16'h1ff8;
                    4'd12: O_row_bits = 16'h1ff8;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_COLON: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0000;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'h0000;
                    4'd5 : O_row_bits = 16'h0000;
                    4'd6 : O_row_bits = 16'h0180;
                    4'd7 : O_row_bits = 16'h0180;
                    4'd8 : O_row_bits = 16'h0000;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0180;
                    4'd11: O_row_bits = 16'h0180;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LT: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0800;
                    4'd3 : O_row_bits = 16'h1000;
                    4'd4 : O_row_bits = 16'h2000;
                    4'd5 : O_row_bits = 16'h4000;
                    4'd6 : O_row_bits = 16'h2000;
                    4'd7 : O_row_bits = 16'h1000;
                    4'd8 : O_row_bits = 16'h0800;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_EQ: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0000;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'h3f00;
                    4'd5 : O_row_bits = 16'h0000;
                    4'd6 : O_row_bits = 16'h0000;
                    4'd7 : O_row_bits = 16'h3f00;
                    4'd8 : O_row_bits = 16'h0000;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_GT: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h8000;
                    4'd3 : O_row_bits = 16'h4000;
                    4'd4 : O_row_bits = 16'h2000;
                    4'd5 : O_row_bits = 16'h1000;
                    4'd6 : O_row_bits = 16'h2000;
                    4'd7 : O_row_bits = 16'h4000;
                    4'd8 : O_row_bits = 16'h8000;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_A: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h1c00;
                    4'd3 : O_row_bits = 16'h1400;
                    4'd4 : O_row_bits = 16'h1400;
                    4'd5 : O_row_bits = 16'h1400;
                    4'd6 : O_row_bits = 16'h3600;
                    4'd7 : O_row_bits = 16'h3e00;
                    4'd8 : O_row_bits = 16'h2200;
                    4'd9 : O_row_bits = 16'h2200;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_B: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h3e00;
                    4'd3 : O_row_bits = 16'h3300;
                    4'd4 : O_row_bits = 16'h3300;
                    4'd5 : O_row_bits = 16'h3e00;
                    4'd6 : O_row_bits = 16'h3300;
                    4'd7 : O_row_bits = 16'h3300;
                    4'd8 : O_row_bits = 16'h3300;
                    4'd9 : O_row_bits = 16'h3e00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_C: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h03f0;
                    4'd3 : O_row_bits = 16'h0c0c;
                    4'd4 : O_row_bits = 16'h1800;
                    4'd5 : O_row_bits = 16'h3000;
                    4'd6 : O_row_bits = 16'h3000;
                    4'd7 : O_row_bits = 16'h3000;
                    4'd8 : O_row_bits = 16'h3000;
                    4'd9 : O_row_bits = 16'h3000;
                    4'd10: O_row_bits = 16'h1800;
                    4'd11: O_row_bits = 16'h0c0c;
                    4'd12: O_row_bits = 16'h03f0;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_D: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h3e00;
                    4'd3 : O_row_bits = 16'h3300;
                    4'd4 : O_row_bits = 16'h3300;
                    4'd5 : O_row_bits = 16'h3300;
                    4'd6 : O_row_bits = 16'h3300;
                    4'd7 : O_row_bits = 16'h3300;
                    4'd8 : O_row_bits = 16'h3600;
                    4'd9 : O_row_bits = 16'h3c00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_E: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h3e00;
                    4'd3 : O_row_bits = 16'h3000;
                    4'd4 : O_row_bits = 16'h3000;
                    4'd5 : O_row_bits = 16'h3e00;
                    4'd6 : O_row_bits = 16'h3000;
                    4'd7 : O_row_bits = 16'h3000;
                    4'd8 : O_row_bits = 16'h3000;
                    4'd9 : O_row_bits = 16'h3e00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_F: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h3e00;
                    4'd3 : O_row_bits = 16'h3000;
                    4'd4 : O_row_bits = 16'h3000;
                    4'd5 : O_row_bits = 16'h3000;
                    4'd6 : O_row_bits = 16'h3e00;
                    4'd7 : O_row_bits = 16'h3000;
                    4'd8 : O_row_bits = 16'h3000;
                    4'd9 : O_row_bits = 16'h3000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_G: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h1c00;
                    4'd3 : O_row_bits = 16'h3200;
                    4'd4 : O_row_bits = 16'h6000;
                    4'd5 : O_row_bits = 16'h6000;
                    4'd6 : O_row_bits = 16'h6e00;
                    4'd7 : O_row_bits = 16'h6600;
                    4'd8 : O_row_bits = 16'h3600;
                    4'd9 : O_row_bits = 16'h1e00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_H: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h3300;
                    4'd3 : O_row_bits = 16'h3300;
                    4'd4 : O_row_bits = 16'h3300;
                    4'd5 : O_row_bits = 16'h3f00;
                    4'd6 : O_row_bits = 16'h3300;
                    4'd7 : O_row_bits = 16'h3300;
                    4'd8 : O_row_bits = 16'h3300;
                    4'd9 : O_row_bits = 16'h3300;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_I: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h1e00;
                    4'd3 : O_row_bits = 16'h0c00;
                    4'd4 : O_row_bits = 16'h0c00;
                    4'd5 : O_row_bits = 16'h0c00;
                    4'd6 : O_row_bits = 16'h0c00;
                    4'd7 : O_row_bits = 16'h0c00;
                    4'd8 : O_row_bits = 16'h0c00;
                    4'd9 : O_row_bits = 16'h1e00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_J: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h3e00;
                    4'd3 : O_row_bits = 16'h0600;
                    4'd4 : O_row_bits = 16'h0600;
                    4'd5 : O_row_bits = 16'h0600;
                    4'd6 : O_row_bits = 16'h0600;
                    4'd7 : O_row_bits = 16'h0600;
                    4'd8 : O_row_bits = 16'h2600;
                    4'd9 : O_row_bits = 16'h1c00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_K: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h3300;
                    4'd3 : O_row_bits = 16'h3600;
                    4'd4 : O_row_bits = 16'h3400;
                    4'd5 : O_row_bits = 16'h3c00;
                    4'd6 : O_row_bits = 16'h3c00;
                    4'd7 : O_row_bits = 16'h3400;
                    4'd8 : O_row_bits = 16'h3600;
                    4'd9 : O_row_bits = 16'h3300;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_L: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h3000;
                    4'd3 : O_row_bits = 16'h3000;
                    4'd4 : O_row_bits = 16'h3000;
                    4'd5 : O_row_bits = 16'h3000;
                    4'd6 : O_row_bits = 16'h3000;
                    4'd7 : O_row_bits = 16'h3000;
                    4'd8 : O_row_bits = 16'h3000;
                    4'd9 : O_row_bits = 16'h3e00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_M: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h3600;
                    4'd3 : O_row_bits = 16'h3600;
                    4'd4 : O_row_bits = 16'h3600;
                    4'd5 : O_row_bits = 16'h3600;
                    4'd6 : O_row_bits = 16'h2a00;
                    4'd7 : O_row_bits = 16'h2a00;
                    4'd8 : O_row_bits = 16'h2200;
                    4'd9 : O_row_bits = 16'h2200;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_N: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h300c;
                    4'd3 : O_row_bits = 16'h380c;
                    4'd4 : O_row_bits = 16'h3c0c;
                    4'd5 : O_row_bits = 16'h360c;
                    4'd6 : O_row_bits = 16'h330c;
                    4'd7 : O_row_bits = 16'h318c;
                    4'd8 : O_row_bits = 16'h30cc;
                    4'd9 : O_row_bits = 16'h306c;
                    4'd10: O_row_bits = 16'h303c;
                    4'd11: O_row_bits = 16'h301c;
                    4'd12: O_row_bits = 16'h300c;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_O: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h1e00;
                    4'd3 : O_row_bits = 16'h3200;
                    4'd4 : O_row_bits = 16'h6300;
                    4'd5 : O_row_bits = 16'h6300;
                    4'd6 : O_row_bits = 16'h6300;
                    4'd7 : O_row_bits = 16'h6300;
                    4'd8 : O_row_bits = 16'h3600;
                    4'd9 : O_row_bits = 16'h3c00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_P: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h3e00;
                    4'd3 : O_row_bits = 16'h3300;
                    4'd4 : O_row_bits = 16'h3300;
                    4'd5 : O_row_bits = 16'h3300;
                    4'd6 : O_row_bits = 16'h3e00;
                    4'd7 : O_row_bits = 16'h3000;
                    4'd8 : O_row_bits = 16'h3000;
                    4'd9 : O_row_bits = 16'h3000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_Q: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h1e00;
                    4'd3 : O_row_bits = 16'h3200;
                    4'd4 : O_row_bits = 16'h6300;
                    4'd5 : O_row_bits = 16'h6300;
                    4'd6 : O_row_bits = 16'h6300;
                    4'd7 : O_row_bits = 16'h6300;
                    4'd8 : O_row_bits = 16'h7600;
                    4'd9 : O_row_bits = 16'h3c00;
                    4'd10: O_row_bits = 16'h0c00;
                    4'd11: O_row_bits = 16'h0700;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_R: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h3e00;
                    4'd3 : O_row_bits = 16'h3300;
                    4'd4 : O_row_bits = 16'h3300;
                    4'd5 : O_row_bits = 16'h3300;
                    4'd6 : O_row_bits = 16'h3c00;
                    4'd7 : O_row_bits = 16'h3600;
                    4'd8 : O_row_bits = 16'h3600;
                    4'd9 : O_row_bits = 16'h3200;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_S: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h1e00;
                    4'd3 : O_row_bits = 16'h3000;
                    4'd4 : O_row_bits = 16'h3000;
                    4'd5 : O_row_bits = 16'h3c00;
                    4'd6 : O_row_bits = 16'h0f00;
                    4'd7 : O_row_bits = 16'h0300;
                    4'd8 : O_row_bits = 16'h0300;
                    4'd9 : O_row_bits = 16'h3e00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_T: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h3ffc;
                    4'd3 : O_row_bits = 16'h03c0;
                    4'd4 : O_row_bits = 16'h03c0;
                    4'd5 : O_row_bits = 16'h03c0;
                    4'd6 : O_row_bits = 16'h03c0;
                    4'd7 : O_row_bits = 16'h03c0;
                    4'd8 : O_row_bits = 16'h03c0;
                    4'd9 : O_row_bits = 16'h03c0;
                    4'd10: O_row_bits = 16'h03c0;
                    4'd11: O_row_bits = 16'h03c0;
                    4'd12: O_row_bits = 16'h03c0;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_U: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h3300;
                    4'd3 : O_row_bits = 16'h3300;
                    4'd4 : O_row_bits = 16'h3300;
                    4'd5 : O_row_bits = 16'h3300;
                    4'd6 : O_row_bits = 16'h3300;
                    4'd7 : O_row_bits = 16'h3300;
                    4'd8 : O_row_bits = 16'h3300;
                    4'd9 : O_row_bits = 16'h1e00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_V: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h2200;
                    4'd3 : O_row_bits = 16'h2200;
                    4'd4 : O_row_bits = 16'h3600;
                    4'd5 : O_row_bits = 16'h3600;
                    4'd6 : O_row_bits = 16'h1400;
                    4'd7 : O_row_bits = 16'h1400;
                    4'd8 : O_row_bits = 16'h1c00;
                    4'd9 : O_row_bits = 16'h1c00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_W: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h2200;
                    4'd3 : O_row_bits = 16'h2200;
                    4'd4 : O_row_bits = 16'h2a00;
                    4'd5 : O_row_bits = 16'h2a00;
                    4'd6 : O_row_bits = 16'h3600;
                    4'd7 : O_row_bits = 16'h3600;
                    4'd8 : O_row_bits = 16'h3600;
                    4'd9 : O_row_bits = 16'h3600;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_X: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h3e00;
                    4'd3 : O_row_bits = 16'h1c00;
                    4'd4 : O_row_bits = 16'h1c00;
                    4'd5 : O_row_bits = 16'h0800;
                    4'd6 : O_row_bits = 16'h1c00;
                    4'd7 : O_row_bits = 16'h1400;
                    4'd8 : O_row_bits = 16'h3600;
                    4'd9 : O_row_bits = 16'h3200;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_Y: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h3180;
                    4'd3 : O_row_bits = 16'h1300;
                    4'd4 : O_row_bits = 16'h1b00;
                    4'd5 : O_row_bits = 16'h1e00;
                    4'd6 : O_row_bits = 16'h0c00;
                    4'd7 : O_row_bits = 16'h0c00;
                    4'd8 : O_row_bits = 16'h0c00;
                    4'd9 : O_row_bits = 16'h0c00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_Z: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h3e00;
                    4'd3 : O_row_bits = 16'h0400;
                    4'd4 : O_row_bits = 16'h0c00;
                    4'd5 : O_row_bits = 16'h0800;
                    4'd6 : O_row_bits = 16'h0800;
                    4'd7 : O_row_bits = 16'h1800;
                    4'd8 : O_row_bits = 16'h1000;
                    4'd9 : O_row_bits = 16'h3e00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_A: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h3e00;
                    4'd3 : O_row_bits = 16'h0200;
                    4'd4 : O_row_bits = 16'h3e00;
                    4'd5 : O_row_bits = 16'h4200;
                    4'd6 : O_row_bits = 16'h4200;
                    4'd7 : O_row_bits = 16'h3d00;
                    4'd8 : O_row_bits = 16'h0000;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_B: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h4000;
                    4'd3 : O_row_bits = 16'h4000;
                    4'd4 : O_row_bits = 16'h7c00;
                    4'd5 : O_row_bits = 16'h4200;
                    4'd6 : O_row_bits = 16'h4200;
                    4'd7 : O_row_bits = 16'h4200;
                    4'd8 : O_row_bits = 16'h7c00;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_C: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0000;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'h3e00;
                    4'd5 : O_row_bits = 16'h4000;
                    4'd6 : O_row_bits = 16'h4000;
                    4'd7 : O_row_bits = 16'h4000;
                    4'd8 : O_row_bits = 16'h3e00;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_D: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0200;
                    4'd3 : O_row_bits = 16'h0200;
                    4'd4 : O_row_bits = 16'h3e00;
                    4'd5 : O_row_bits = 16'h4200;
                    4'd6 : O_row_bits = 16'h4200;
                    4'd7 : O_row_bits = 16'h4200;
                    4'd8 : O_row_bits = 16'h3e00;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_E: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0000;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'h3e00;
                    4'd5 : O_row_bits = 16'h4200;
                    4'd6 : O_row_bits = 16'h7e00;
                    4'd7 : O_row_bits = 16'h4000;
                    4'd8 : O_row_bits = 16'h3e00;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_F: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h1e00;
                    4'd3 : O_row_bits = 16'h2000;
                    4'd4 : O_row_bits = 16'h7c00;
                    4'd5 : O_row_bits = 16'h2000;
                    4'd6 : O_row_bits = 16'h2000;
                    4'd7 : O_row_bits = 16'h2000;
                    4'd8 : O_row_bits = 16'h2000;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_G: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0000;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'h3e00;
                    4'd5 : O_row_bits = 16'h4200;
                    4'd6 : O_row_bits = 16'h4200;
                    4'd7 : O_row_bits = 16'h3e00;
                    4'd8 : O_row_bits = 16'h0200;
                    4'd9 : O_row_bits = 16'h3c00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_H: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h4000;
                    4'd3 : O_row_bits = 16'h4000;
                    4'd4 : O_row_bits = 16'h7c00;
                    4'd5 : O_row_bits = 16'h4200;
                    4'd6 : O_row_bits = 16'h4200;
                    4'd7 : O_row_bits = 16'h4200;
                    4'd8 : O_row_bits = 16'h4200;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_I: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h2000;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'h7000;
                    4'd5 : O_row_bits = 16'h2000;
                    4'd6 : O_row_bits = 16'h2000;
                    4'd7 : O_row_bits = 16'h2000;
                    4'd8 : O_row_bits = 16'h7000;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_J: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0800;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'h1800;
                    4'd5 : O_row_bits = 16'h0800;
                    4'd6 : O_row_bits = 16'h0800;
                    4'd7 : O_row_bits = 16'h0800;
                    4'd8 : O_row_bits = 16'h0800;
                    4'd9 : O_row_bits = 16'h8800;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_K: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h4000;
                    4'd3 : O_row_bits = 16'h4000;
                    4'd4 : O_row_bits = 16'h4400;
                    4'd5 : O_row_bits = 16'h4800;
                    4'd6 : O_row_bits = 16'h7000;
                    4'd7 : O_row_bits = 16'h4800;
                    4'd8 : O_row_bits = 16'h4400;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_L: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h6000;
                    4'd3 : O_row_bits = 16'h2000;
                    4'd4 : O_row_bits = 16'h2000;
                    4'd5 : O_row_bits = 16'h2000;
                    4'd6 : O_row_bits = 16'h2000;
                    4'd7 : O_row_bits = 16'h2000;
                    4'd8 : O_row_bits = 16'h7000;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_M: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0000;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'hd800;
                    4'd5 : O_row_bits = 16'ha400;
                    4'd6 : O_row_bits = 16'ha400;
                    4'd7 : O_row_bits = 16'ha400;
                    4'd8 : O_row_bits = 16'ha400;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_N: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0000;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'h7c00;
                    4'd5 : O_row_bits = 16'h4200;
                    4'd6 : O_row_bits = 16'h4200;
                    4'd7 : O_row_bits = 16'h4200;
                    4'd8 : O_row_bits = 16'h4200;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_O: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0000;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'h3e00;
                    4'd5 : O_row_bits = 16'h4200;
                    4'd6 : O_row_bits = 16'h4200;
                    4'd7 : O_row_bits = 16'h4200;
                    4'd8 : O_row_bits = 16'h3e00;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_P: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0000;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'h7c00;
                    4'd5 : O_row_bits = 16'h4200;
                    4'd6 : O_row_bits = 16'h4200;
                    4'd7 : O_row_bits = 16'h7c00;
                    4'd8 : O_row_bits = 16'h4000;
                    4'd9 : O_row_bits = 16'h4000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_Q: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0000;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'h3e00;
                    4'd5 : O_row_bits = 16'h4200;
                    4'd6 : O_row_bits = 16'h4200;
                    4'd7 : O_row_bits = 16'h3e00;
                    4'd8 : O_row_bits = 16'h0200;
                    4'd9 : O_row_bits = 16'h0200;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_R: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0000;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'h5c00;
                    4'd5 : O_row_bits = 16'h6200;
                    4'd6 : O_row_bits = 16'h4000;
                    4'd7 : O_row_bits = 16'h4000;
                    4'd8 : O_row_bits = 16'h4000;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_S: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0000;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'h3e00;
                    4'd5 : O_row_bits = 16'h4000;
                    4'd6 : O_row_bits = 16'h3c00;
                    4'd7 : O_row_bits = 16'h0200;
                    4'd8 : O_row_bits = 16'h7c00;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_T: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h2000;
                    4'd3 : O_row_bits = 16'h2000;
                    4'd4 : O_row_bits = 16'h7c00;
                    4'd5 : O_row_bits = 16'h2000;
                    4'd6 : O_row_bits = 16'h2000;
                    4'd7 : O_row_bits = 16'h2000;
                    4'd8 : O_row_bits = 16'h1c00;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_U: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0000;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'h4200;
                    4'd5 : O_row_bits = 16'h4200;
                    4'd6 : O_row_bits = 16'h4200;
                    4'd7 : O_row_bits = 16'h4200;
                    4'd8 : O_row_bits = 16'h3d00;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_V: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0000;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'h4200;
                    4'd5 : O_row_bits = 16'h4200;
                    4'd6 : O_row_bits = 16'h2400;
                    4'd7 : O_row_bits = 16'h2400;
                    4'd8 : O_row_bits = 16'h1000;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_W: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0000;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'h8200;
                    4'd5 : O_row_bits = 16'h8200;
                    4'd6 : O_row_bits = 16'h9200;
                    4'd7 : O_row_bits = 16'h9200;
                    4'd8 : O_row_bits = 16'h6c00;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_X: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0000;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'h4200;
                    4'd5 : O_row_bits = 16'h2400;
                    4'd6 : O_row_bits = 16'h1000;
                    4'd7 : O_row_bits = 16'h2400;
                    4'd8 : O_row_bits = 16'h4200;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_Y: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0000;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'h4200;
                    4'd5 : O_row_bits = 16'h4200;
                    4'd6 : O_row_bits = 16'h4200;
                    4'd7 : O_row_bits = 16'h3e00;
                    4'd8 : O_row_bits = 16'h0200;
                    4'd9 : O_row_bits = 16'h3c00;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LOW_Z: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0000;
                    4'd1 : O_row_bits = 16'h0000;
                    4'd2 : O_row_bits = 16'h0000;
                    4'd3 : O_row_bits = 16'h0000;
                    4'd4 : O_row_bits = 16'h7e00;
                    4'd5 : O_row_bits = 16'h0c00;
                    4'd6 : O_row_bits = 16'h3000;
                    4'd7 : O_row_bits = 16'h6000;
                    4'd8 : O_row_bits = 16'h7e00;
                    4'd9 : O_row_bits = 16'h0000;
                    4'd10: O_row_bits = 16'h0000;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_AN: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h0200;
                    4'd1 : O_row_bits = 16'h7ff0;
                    4'd2 : O_row_bits = 16'h4410;
                    4'd3 : O_row_bits = 16'h0400;
                    4'd4 : O_row_bits = 16'h7ff0;
                    4'd5 : O_row_bits = 16'h0840;
                    4'd6 : O_row_bits = 16'h1040;
                    4'd7 : O_row_bits = 16'h1c80;
                    4'd8 : O_row_bits = 16'h0300;
                    4'd9 : O_row_bits = 16'h0cc0;
                    4'd10: O_row_bits = 16'h7020;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            CHAR_LU: begin
                case (I_row)
                    4'd0 : O_row_bits = 16'h79e0;
                    4'd1 : O_row_bits = 16'h4a20;
                    4'd2 : O_row_bits = 16'h4d40;
                    4'd3 : O_row_bits = 16'h7880;
                    4'd4 : O_row_bits = 16'h1140;
                    4'd5 : O_row_bits = 16'h1630;
                    4'd6 : O_row_bits = 16'h5be0;
                    4'd7 : O_row_bits = 16'h5220;
                    4'd8 : O_row_bits = 16'h5220;
                    4'd9 : O_row_bits = 16'h5be0;
                    4'd10: O_row_bits = 16'h6220;
                    4'd11: O_row_bits = 16'h0000;
                    4'd12: O_row_bits = 16'h0000;
                    4'd13: O_row_bits = 16'h0000;
                    4'd14: O_row_bits = 16'h0000;
                    4'd15: O_row_bits = 16'h0000;
                    default: O_row_bits = 16'h0000;
                endcase
            end
            default: O_row_bits = 16'h0000;
        endcase
    end

endmodule
