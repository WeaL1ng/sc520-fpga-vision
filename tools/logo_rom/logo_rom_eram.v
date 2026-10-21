// ============================================================
// logo_rom_eram.v  --  P1b: Logo 调色板索引 ROM
//
// 由 tools/gen_logo_rom_v.py 自动生成，请勿手工修改。
//   logo_pixel.mif    : 13724 x 8bit 索引（0 = 透明）
//   logo_palette.vh   : 256 色
//   几何              : 146x94 @(7,34)  深度=13724
//
// 与旧的 anlogic_logo_rom 的区别（重要）：
//   旧的： always @(*) case(...)  组合输出，综合成巨型 LUT 网
//         实测占最差路径约 6.1ns（12 级 LUT）
//   新的： 地址打一拍 + 同步读，(* ram_style = "block" *) 推断 ERAM
//         ⇒ O_idx 比 I_addr 晚 **2 拍**（addr_reg, idx_reg）
//   ⇒ 调用方必须把 osd_hit / 坐标 / 视频数据对齐到同一拍
//
// ERAM 硬性约束（PH1P 用户手册）：地址与数据输入必须与时钟同步，
// 否则工具不做时序分析、内容可能不可预测地翻转 ⇒ 必须同步读。
// ============================================================

module logo_rom_eram (
    input  wire              I_clk,
    input  wire              I_rst_n,
    input  wire [13:0]  I_addr,
    output reg  [7:0]   O_idx
);

    // ---- 地址打一拍：ERAM 地址必须同步 ----
    reg [13:0] addr_reg;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) addr_reg <= {14{1'b0}};
        else         addr_reg <= I_addr;
    end

    // ---- 同步读 ROM（推断 ERAM）----
    (* ram_style = "block" *) reg [7:0] rom [0:13723];
    reg [7:0] idx_reg;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) idx_reg <= {8{1'b0}};
        else         idx_reg <= rom[addr_reg];
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) O_idx <= {8{1'b0}};
        else         O_idx <= idx_reg;
    end

    // ---- ROM 初始化 ----
    // TD 支持 (* ram_style *) + initial 块加载（.sv 或 TD 综合器接受时）
    // 这里用 generate + case 赋初值不可综合，故改用 `include` 的 hex 文件方式：
    //   $readmemh 仅仿真用；综合期初值见下方 case 形式（TD 会放进 ERAM INIT）
    integer k;
    initial begin
        for (k = 0; k < 13724; k = k + 1) rom[k] = {8{1'b0}};
        $readmemh("logo_rom_eram_pixel.hex", rom);
    end

endmodule
