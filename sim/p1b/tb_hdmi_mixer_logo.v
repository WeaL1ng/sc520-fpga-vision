// ============================================================================
//  tb_hdmi_mixer_logo.v
//  P1b 验证 testbench：确认 Logo 在**绝对屏幕位置**上没有 1 像素偏移
//
//  背景
//    P1b 把 Logo ROM 从"组合 case"改成"同步读 ERAM"（多 1 拍延迟），
//    并把地址计算提前到 _1d 坐标级来吸收这一拍。
//    这个对齐**之前只是推导，未做任何仿真或上板验证**。
//
//  方法（不猜测：直接用本地源数据算出"应该在哪儿"）
//    1) Python 侧解析 logo_pixel.mif + logo_palette.vh，展开成 146x94 的
//       非透明包围盒。按 P1b 的几何，非透明像素应出现在屏幕:
//           x in [LOGO_ROM_X0 + minx, ...], y in [LOGO_ROM_Y0 + miny, ...]
//       本 TB 只负责把 hdmi_mixer 的一帧输出（含 OSD）写成文本
//    2) 仿真：喂一帧 1280x720 的确定性图案（像素值 = 坐标编码），
//       I_osd_en=1，逐拍按 O_hdmi_de 重建输出像素
//    3) Python 侧从输出里找出"非视频编码"像素的包围盒，与 (1) 比对
//
//  为什么输出文本而不是二进制 PPM
//    Verilog 的 %c 在写二进制时对 0x00 等值不可靠；改写成 6 位十六进制文本，
//    由 Python 解析。像素数 1280x720 = 921600，输出约 6.5 MB 文本，可接受。
//
//  运行：
//    vlib work
//    vlog hdmi_mixer.v logo_rom_eram.v osd_char_lib.v tb_hdmi_mixer_logo.v
//    vsim -batch -lib work tb_hdmi_mixer_logo -do "run -all; quit -f"
// ============================================================================
`timescale 1ns/1ps

module tb_hdmi_mixer_logo;

    localparam integer IMG_W = 1280;
    localparam integer IMG_H = 720;
    localparam integer H_TOT = 1650;
    localparam integer V_TOT = 750;

    reg clk = 0;
    reg rst_n = 0;
    always #1 clk = ~clk;      // 250 MHz 仿真时钟，只跑逻辑，缩短墙上时间

    reg  [11:0] S_x = 0;
    reg  [11:0] S_y = 0;
    reg         de  = 0;
    reg         user = 0;
    reg         last = 0;

    // 输入像素值：把坐标编进去，使得任意两个不同坐标的编码都不同
    //   像素 = {x[4:0], y[4:0], x[9:5], 4'b0}   —— 16bit，占 24bit 的高 16 位
    //   这样非 OSD 区域出现的一定是"编码值"，OSD 区域是 Logo 调色板颜色
    wire [23:0] din_code = {S_x[4:0], S_y[4:0], S_x[9:5], 4'b0000};
    // ---- OSD 开关与输出名由 plusarg 控制，便于跑两次做差 ----
    //   +osd=0 -> 无 Logo（背景基准）  +osd=1 -> 有 Logo
    // 注意：声明必须在被实例端口引用之前（Verilog-2001 先用后声明会报 vlog-2388）
    reg          osd_sw  = 1'b1;
    reg [1023:0] outname = "logo_out.hex";

    reg  [23:0] din_r = 24'd0;
    always @(posedge clk) din_r <= din_code;

    wire        O_video_rd_en;
    wire        O_hdmi_vsync, O_hdmi_hsync, O_hdmi_de;
    wire [23:0] O_hdmi_data;

    hdmi_mixer #(
        .H_OFFSET (128), .V_OFFSET (60),
        .IMG_WIDTH(IMG_W), .IMG_HEIGHT(IMG_H), .DEBUG_MODE(0)
    ) dut (
        .I_clk(clk), .I_rst_n(rst_n),
        .I_video_vsync(1'b0), .I_video_hsync(1'b0),
        .I_video_de(de), .I_video_user(user), .I_video_last(last),
        .I_debug_status(4'b0000),
        .I_osd_en(osd_sw),
        .I_mode_disp(2'b00),
        // ---- ★ P3 新增端口：必须显式驱动，否则浮空成 x，
        //      会让延迟文本区输出不确定值，破坏"两次仿真做差"的判据 ----
        //   I_lat_ms=0 + I_lat_valid=0  =>  显示 "LATENCY: --- ms"（占位）
        //   该区在 osd=0 / osd=1 两次运行里**完全相同**，故在做差中被抵消，
        //   不影响 Logo 位置判定。
        .I_lat_ms(32'd0),
        .I_lat_valid(1'b0),
        .O_dis_frame_start(),
        .O_video_rd_en(O_video_rd_en),
        .I_video_rd_data(din_r),
        .O_hdmi_vsync(O_hdmi_vsync), .O_hdmi_hsync(O_hdmi_hsync),
        .O_hdmi_de(O_hdmi_de), .O_hdmi_data(O_hdmi_data)
    );


    integer errors = 0, checks = 0;
    integer fd;
    integer total_out = 0;
    integer n_line = 0;

    task drive_frame;
        integer xx, yy;
        begin
            user = 1'b1; de = 1'b0; last = 1'b0;
            S_x = 0; S_y = 0;
            @(posedge clk);
            user = 1'b0;
            for (yy = 0; yy < V_TOT; yy = yy + 1) begin
                for (xx = 0; xx < H_TOT; xx = xx + 1) begin
                    if (yy < IMG_H && xx < IMG_W) begin
                        S_x  = xx[11:0];
                        S_y  = yy[11:0];
                        de   = 1'b1;
                        last = (xx == IMG_W-1);
                    end else begin
                        de = 1'b0; last = 1'b0;
                    end
                    @(posedge clk);
                end
                de = 1'b0; last = 1'b0;
                repeat (4) @(posedge clk);
            end
            de = 1'b0; user = 1'b0; last = 1'b0;
            repeat (40) @(posedge clk);
        end
    endtask

    // 输出采样：按 O_hdmi_de 计像素，写成 6 位十六进制文本
    always @(posedge clk) begin
        if (O_hdmi_de) begin
            $fwrite(fd, "%06x\n", O_hdmi_data);
            total_out = total_out + 1;
        end
    end

    initial begin
        $display("============================================================");
        $display(" tb_hdmi_mixer_logo : verify P1b Logo absolute position");
        $display("============================================================");

        if ($value$plusargs("osd=%d", osd_sw)) ;
        if ($value$plusargs("out=%s", outname)) ;
        $display("  osd_sw = %0d   out = %0s", osd_sw, outname);

        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        fd = $fopen(outname, "w");
        if (fd == 0) begin
            $display("  [FAIL] cannot open output file");
            $finish;
        end

        drive_frame;
        $fclose(fd);

        $display("  output DE-active pixels = %0d  (expect %0d)", total_out, IMG_W*IMG_H);
        checks = checks + 1;
        if (total_out != IMG_W*IMG_H) begin
            errors = errors + 1;
            $display("  [FAIL] DE pixel count mismatch");
        end else begin
            $display("  [ ok ] DE pixel count exactly %0d", IMG_W*IMG_H);
        end

        $display("  wrote logo_out.hex");
        $display("============================================================");
        if (errors == 0) $display("  TB done: checks=%0d errors=0", checks);
        else             $display("  TB done: checks=%0d errors=%0d", checks, errors);
        $display("============================================================");
        $finish;
    end

    initial begin
        #200000000;
        $display("  [FAIL] simulation timeout");
        $finish;
    end

endmodule
