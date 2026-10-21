module hdmi_mixer #(
    parameter H_OFFSET = 128,
    parameter V_OFFSET = 60,
    parameter IMG_WIDTH = 1280,
    parameter IMG_HEIGHT = 720,
    parameter integer DEBUG_MODE = 0
)(
    input wire        I_clk,
    input wire        I_rst_n,

    input wire        I_video_vsync,
    input wire        I_video_hsync,
    input wire        I_video_de,
    input wire        I_video_user,
    input wire        I_video_last,

    input wire[3:0]   I_debug_status,

    // ---- lab_ex4 新增 ----------------------------------------------------
    // I_osd_en   : 1 = 显示 OSD（安路 Logo + 动态文字）; 0 = 只显示视频
    //              来源 key_mode_ctrl.O_mode[1]
    // I_mode_disp: 当前模式值, 显示为右上角数字 0..4（P4 扩为 3 位）
    //              来源 key_mode_ctrl.O_mode[1:0]（D4 域, 同组同步）
    input wire        I_osd_en,
    input wire[2:0]   I_mode_disp,
    // ----------------------------------------------------------------------

    output wire       O_video_rd_en,
    input wire[23:0]  I_video_rd_data,

    // ---- ★ P3 新增：端到端延迟可视化（高阶要求③）----
    input wire[31:0]  I_lat_ms,        // 延迟值（毫秒），由 frame_latency 提供
    input wire        I_lat_valid,     // 0 = 尚未测出，显示占位符 "---"
    output wire       O_dis_frame_start, // 显示帧起始脉冲（供 frame_latency 计帧）

    // ---- ★ P5 新增：颜色目标检测结果（扩展② + 进阶②）----
    //  全部已在 design_top_wrapper 里跨到本域并**寄存**（准静态，每帧一次）。
    //  ⚠ 不要把 ISP 域的原始信号直接接进来 —— P3 的教训就是"帧率信号进像素级组合云"。
    input wire        I_tgt_valid,
    input wire[10:0]  I_tgt_x_min,
    input wire[10:0]  I_tgt_x_max,
    input wire[9:0]   I_tgt_y_min,
    input wire[9:0]   I_tgt_y_max,
    input wire[7:0]   I_tgt_tiles,
    input wire[1:0]   I_tgt_shape,      // 0=NONE 1=BAR 2=BLOCK
    input wire[3:0]   I_tgt_x_d3,       // X 千/百/十/个（十进制位在 ISP 域算好）
    input wire[3:0]   I_tgt_x_d2,
    input wire[3:0]   I_tgt_x_d1,
    input wire[3:0]   I_tgt_x_d0,
    input wire[3:0]   I_tgt_y_d2,       // Y 百/十/个
    input wire[3:0]   I_tgt_y_d1,
    input wire[3:0]   I_tgt_y_d0,
    //  ★★ 临时诊断（上板定位用；定位完连同 OSD 那一行一起删）
    input wire[7:0]   I_tgt_dbg_beat,   // 本帧拍数 ÷1024（流正常时 = 0xE1 = 225）
    input wire[19:0]  I_tgt_dbg_warm,   // 本帧暖色像素数
    input wire[7:0]   I_tgt_dbg_cb,     // 探测像素 Cb
    input wire[7:0]   I_tgt_dbg_cr,     // 探测像素 Cr
    // ---- ★ P6：AE 闭环状态（区域 AEINFO_X/Y，见下方注释）----
    input wire        I_ae_en,          // 1=自动 0=手动（显示 'A' / 'M'）
    input wire[15:0]  I_ae_val,         // 当前曝光值（4 位十六进制）
    input wire[15:0]  I_ae_ag,          // 当前模拟增益（2 位十六进制）
    input wire[7:0]   I_ae_luma,        // 本帧平均亮度（2 位十六进制）
    input wire[19:0]  I_ae_clip,        // 本帧过曝像素数（保留：高光保护的可观测证据）
    input wire[1:0]   I_ae_sat,         // ★ 执行机构饱和：bit1=顶上(+) bit0=抵下(-)
    // ---- ★ P7：运动检测（运动框 + 运动计数行）----
    input wire[10:0]  I_mot_x_min,
    input wire[10:0]  I_mot_x_max,
    input wire[9:0]   I_mot_y_min,
    input wire[9:0]   I_mot_y_max,
    input wire[13:0]  I_mot_blkcnt,     // 运动块数（**不是目标个数**）
    input wire        I_mot_valid,
    input wire        I_mot_global,     // 本帧被判为全局光照突变

    output reg        O_hdmi_vsync,
    output reg        O_hdmi_hsync,
    output reg        O_hdmi_de,
    output reg[23:0]  O_hdmi_data
);

    reg        S_video_vsync_1d;
    reg        S_video_vsync_2d;
    reg        S_video_hsync_1d;
    reg        S_video_hsync_2d;
    reg        S_video_de_1d;
    reg        S_video_de_2d;
    reg [23:0] S_video_data_1d;
    reg [23:0] S_video_data_2d;
    reg [11:0] S_x;
    reg [11:0] S_y;
    reg [11:0] S_x_1d;
    reg [11:0] S_x_2d;
    reg [11:0] S_y_1d;
    reg [11:0] S_y_2d;

    // [P1b 2026-09-20] Logo ROM changed to synchronous ERAM read.
    // Old: anlogic_logo_rom = always@(*) case(...) -> huge combinational LUT mesh,
    //      measured ~6.1ns / 12 LUT levels on the HDMI_PIXEL_CLK critical path.
    // New: logo_rom_eram registers address+output internally (1 cycle later than
    //      the old one) and uses (* ram_style="block" *) so TD infers ERAM.
    // Address is computed one stage earlier (from _1d coords) so the extra ROM
    // cycle is absorbed and the Logo stays aligned with S_video_data_2d.
    localparam LOGO_ROM_X0 = 12'd7;    // cropped region origin (logo_geom.vh)
    localparam LOGO_ROM_Y0 = 12'd34;
    localparam LOGO_ROM_W  = 12'd146;
    localparam LOGO_ROM_H  = 12'd94;

    reg  [14:0] S_logo_rowb_cur;    // row base address of the current row
    reg  [14:0] S_logo_rowb_pre;    // row base of the previous row
    reg         S_logo_in_v;        // was previous cycle inside the Logo v-range
    wire [13:0] S_logo_addr14;      // ROM address (ROM registers it internally)
    wire [7:0]  S_logo_idx;         // palette index out of the ROM
    reg  [23:0] S_logo_pixel_r;     // registered palette lookup result

    reg        S_osd_hit;
    reg [23:0] S_osd_color;
    reg [3:0]  S_char_idx;
    reg [2:0]  S_char_row;
    reg [2:0]  S_char_col;
    reg [4:0]  S_char_bits;
    reg        S_char_on;
    reg        S_logo_blue_on;
    reg        S_logo_red_on;
    reg [11:0] S_logo_tmp_y;
    reg [3:0]  S_logo_red_band;
    reg [11:0] S_logo_red_x_start;
    reg [11:0] S_logo_red_x_end;
    reg [31:0] S_frame_cnt;
    reg [11:0] S_dyn_x;
    reg [11:0] S_dyn_y;
    reg [3:0]  S_dyn_char;
    reg [2:0]  S_dyn_col;
    reg [2:0]  S_dyn_row;
    reg [4:0]  S_dyn_bits;
    reg        S_dyn_on;
    reg [3:0]  S_dyn_digit_idx;
    reg [11:0] S_dyn_digit_x;
    reg [6:0]  S_dyn_seg;
    reg [3:0]  S_cnt_d0;
    reg [3:0]  S_cnt_d1;
    reg [3:0]  S_cnt_d2;
    reg [3:0]  S_cnt_d3;
    reg [3:0]  S_cnt_d4;
    reg [3:0]  S_cnt_d5;
    reg [2:0]  S_lbl_row;
    reg [2:0]  S_lbl_col;
    reg [1:0]  S_lbl_idx;
    reg [4:0]  S_lbl_bits;
    reg [6:0]  S_lbl_local_x;
    reg [3:0]  S_dyn_dec_digit;
    reg [4:0]  S_cn_local_x;
    reg [4:0]  S_cn_local_y;
    reg [3:0]  S_cn_col;
    reg [3:0]  S_cn_row;
    reg [15:0] S_cn_row_bits;
    reg        S_cn_on;
    reg [9:0]  S_cn_scale_x;
    reg [9:0]  S_cn_scale_y;
    reg [7:0]  S_pf_char;
    reg [4:0]  S_pf_local_x;
    reg [4:0]  S_pf_local_y;
    reg [3:0]  S_pf_col;
    reg [3:0]  S_pf_row;
    wire [15:0] S_pf_row_bits;
    reg        S_pf_on;
    reg [9:0]  S_pf_scale_x;
    reg [9:0]  S_pf_scale_y;

    // ---- lab_ex4 新增：状态条 / 模式数字 的判决结果 ----
    reg        S_stat_hit;      // 当前像素落在状态条区域
    reg [23:0] S_stat_color;    // 状态条颜色
    reg        S_mode_hit;      // 当前像素落在模式数字字形内
    reg [23:0] S_mode_color;    // 模式数字颜色
    reg [11:0] S_md_local_x;    // 模式数字局部坐标
    reg [11:0] S_md_local_y;
    reg [6:0]  S_md_seg;        // mode 的 7 段码
    reg        S_md_a;          // 各段点亮标志
    reg        S_md_b;
    reg        S_md_c;
    reg        S_md_d;
    reg        S_md_e;
    reg        S_md_f;
    reg        S_md_g;
    reg [1:0]  S_stat_idx;      // 状态条段号 0..3

    // ---- ★ P5 新增：目标包围框 + 目标文字的判决结果 ----
    reg        S_box_hit;       // 当前像素落在包围框边线上
    reg [23:0] S_box_color;
    reg        S_tgt_hit;       // 当前像素落在目标文字笔画上
    reg [23:0] S_tgt_color;
    reg [11:0] S_tgt_local_x;
    reg [11:0] S_tgt_local_y;
    reg [7:0]  S_tgt_char;
    reg        S_tgt_on;

    // ---- ★ P6 新增：AE 状态文字（与 P5 同一套机制，只是显示十六进制）----
    reg        S_ae_hit;        // 当前像素落在 AE 文字笔画上
    reg [23:0] S_ae_color;
    reg [11:0] S_ae_local_x;
    reg [11:0] S_ae_local_y;
    reg [7:0]  S_ae_char;
    reg        S_ae_on;

    // ---- ★ 目标坐标行（与 P5 目标文字同一套机制）----
    reg        S_tpos_hit;
    reg [23:0] S_tpos_color;
    reg [11:0] S_tpos_local_x;
    reg [11:0] S_tpos_local_y;
    reg [7:0]  S_tpos_char;
    reg        S_tpos_on;

    // ---- ★ P7：运动框 + 运动计数行 ----
    reg        S_mbox_hit;
    reg [23:0] S_mbox_color;
    reg        S_minfo_hit;
    reg [23:0] S_minfo_color;
    reg [11:0] S_minfo_local_x;
    reg [11:0] S_minfo_local_y;
    reg [7:0]  S_minfo_char;
    reg        S_minfo_on;

  // ---- ★ P3 新增：延迟文本区域 "LATENCY: ### ms" ----
  //  注意：字符码与点阵行**直接复用**既有的 `S_pf_char`/`S_pf_row`
  //  （全模块唯一一个 osd_char_lib 例化的输入），故此处不再另设字符寄存器。
  reg        S_lat_hit;        // 当前像素是否落在延迟文本的**笔画**上
  reg [23:0] S_lat_color;      // 延迟文本颜色
  reg [11:0] S_lat_local_x;    // 文本区域局部 X
  reg [11:0] S_lat_local_y;    // 文本区域局部 Y
  reg [7:0]  S_lat_char;       // 当前字符码
  reg        S_lat_on;         // 字模取位结果
  reg [3:0]  S_lat_d1;         // 延迟值 百位
  reg [3:0]  S_lat_d2;         // 十位
  reg [3:0]  S_lat_d3;         // 个位
  reg [9:0]  S_lat_v;          // 钳位后的延迟值 0..999
  reg [9:0]  S_lat_r;          // v - 百位*100（余数 0..99）—— 替代 % 运算
  reg [9:0]  S_lat_r2;         // 余数 - 十位*10（个位）—— 替代 % 运算
  // ★ 流水寄存器：把"十进制转换"与"字模查表"分成两级
  //   延迟值每帧才更新一次，加一拍流水对显示**完全无损**；
  //   但能把 HDMI_PIXEL_CLK 域的关键路径从 17 级切断（实测教训）。
  reg [3:0]  S_lat_d1_r;       // 已寄存的百位
  reg [3:0]  S_lat_d2_r;       // 已寄存的十位
  reg [3:0]  S_lat_d3_r;       // 已寄存的个位
  reg        S_lat_valid_r;    // 与上面三位同拍（保持流水对齐）
  // 显示帧起始脉冲（vsync 上升沿）
  reg        S_vsync_d;        // O_hdmi_vsync 打一拍，用于边沿检测

    localparam LOGO_X = 12'd0;
    localparam LOGO_Y = 12'd0;
    localparam LOGO_W = 12'd160;
    localparam LOGO_H = 12'd160;

    localparam COLOR_LOGO_BLUE   = 24'h1f315c;
    localparam COLOR_LOGO_RED    = 24'hec1c2d;
    localparam COLOR_TEXT        = 24'h00e6ff;
    localparam DYN_OSD_X         = 12'd375;
    localparam DYN_OSD_Y         = 12'd120;
    localparam DYN_OSD_W         = 12'd200;
    localparam DYN_OSD_H         = 12'd24;
    localparam CN_Y_OFFSET       = 12'd2;
    localparam COLOR_DYN_TEXT    = 24'hfff200;
    localparam CHAR_AN           = 8'h80;
    localparam CHAR_LU           = 8'h81;
    localparam CHAR_C            = 8'h43;
    localparam CHAR_N            = 8'h4e;
    localparam CHAR_T            = 8'h54;
    localparam CHAR_0            = 8'h30;
    localparam CHAR_COLON        = 8'h3a;

    // ========================================================================
    // lab_ex4 新增：常显底部状态条 + 右上模式数字
    // ------------------------------------------------------------------------
    // 约束（doc/arch/module_partition.md §4）：**不新增任何 RAM/ROM**，
    // 状态条与模式数字必须用**纯组合比较**实现。下面只用 localparam 与比较器。
    //
    // 显示优先级（doc/arch/top_skeleton.sv:548 声明）：
    //       OSD(I_osd_en) > 状态条 > 模式数字 > 视频
    // ========================================================================

    // ---- 底部状态条：4 段等分，数据源是 lab1 已有的 I_debug_status[3:0] ----
    // lab1 已把这 4 位同步到 D4 域，本轮**只改变"是否显示"**，不新增同步器。
    localparam STATUS_H    = 12'd24;                                  // 条高
    localparam STATUS_Y    = IMG_HEIGHT - STATUS_H;                   // 贴底
    localparam STATUS_SEGW = IMG_WIDTH / 4;                           // 每段宽 = 320

    localparam COLOR_STAT_ON_0  = 24'hff8000;   // cam_cfg_done   橙（同 DEBUG_MODE=3）
    localparam COLOR_STAT_ON_1  = 24'hffff00;   // hs_seen        黄
    localparam COLOR_STAT_ON_2  = 24'hff0000;   // frame_repeat   红
    localparam COLOR_STAT_ON_3  = 24'h00ffff;   // width_1280     青
    localparam COLOR_STAT_OFF   = 24'h181818;   // 灭：近黑（不刺眼）

    // ---- 右上模式数字：7 段数码管风格，11x19 像素 ----
    localparam MODE_W  = 12'd16;                // 含 5 像素右边距
    localparam MODE_H  = 12'd32;                // 含 13 像素上边距
    localparam MODE_X  = IMG_WIDTH  - MODE_W;   // 右上角
    localparam MODE_Y  = 12'd0;
    localparam MODE_DW = 12'd11;                // 字形宽
    localparam MODE_DH = 12'd19;                // 字形高
    localparam MODE_T  = 12'd3;                 // 笔画粗细

  // ---- ★ P3 新增：延迟文本区域 "LATENCY: ### ms" ----
  //  ⚠ 位置必须与既有区域**互不重叠**（本项目踩过坑：第一版放在 (16,48)，
  //    误以为"Logo 只占左上 160 像素"，实际 Logo 纵向到 row 127，
  //    结果文本压在 Logo 下缘 137x16 像素上）。
  //
  //  实测各区域矩形（由 tools/verify_osd_layout.py 抽取本文件常量得出）：
  //      Logo(安路)    (  7, 34)  146x94   列 7..152   行 34..127
  //      动态文本CNT    (375, 120)  200x24   列 375..574  行 120..143
  //      底部状态条     (  0, 696) 1280x24
  //      模式数字       (1264,  0)   11x19
  //  ⇒ 本区选 **(256, 48)**：Logo 右侧（列 >152）、CNT 左侧（列 <375），
  //    纵向 48..63 也在 CNT 的 120 之上，**四者都不重叠**。
  //     校验命令：python tools\verify_osd_layout.py
  localparam LAT_X     = 12'd256;
  localparam LAT_Y     = 12'd48;
  localparam LAT_W     = 12'd224;              // 14 槽 x 16 = 224
  localparam LAT_H     = 12'd16;
  localparam LAT_CELL  = 12'd16;               // 字符槽宽
  localparam COLOR_LAT = 24'h40ff80;           // 亮绿，与状态栏/动态文本区分

  // ---- ★ P5 新增：目标检测文字区 "BLK 0312,0208"（13 槽 = 208x16）----
  //  ⚠ 位置必须与既有 5 个区域**互不重叠**（P3 就在这里踩过坑：第一版放 (16,48)
  //    压了 Logo 下缘 137x16 像素）。本区选 **(256,80)**：
  //        Logo      (  7, 34) 146x94  → 列 7..152，行 34..127
  //        LATENCY   (256, 48) 224x16  → 列 256..479，行 48..63
  //        本区      (256, 80) 208x16  → 列 256..463，行 80..95   ← 在 LATENCY 之下、
  //                                      CNT（行 120..143）之上，且列 > 152 不压 Logo
  //        动态文本CNT(375,120) 200x24
  //        底部状态条 (0,696) 1280x24
  //        模式数字   (1264, 0) 11x19
  //     校验：python tools\verify_osd_layout.py
  localparam TGT_X     = 12'd256;
  localparam TGT_Y     = 12'd80;
  localparam TGT_W     = 12'd256;              // ★ 诊断版 16 槽 x 16 = 256（正式版为 208）
  localparam TGT_H     = 12'd16;
  localparam COLOR_BOX = 24'hff2040;           // 包围框：红（与状态条的纯红区分：偏洋红）
  localparam COLOR_TGT = 24'hffd040;           // 目标文字：琥珀，与延迟文本亮绿区分
  localparam BOX_T     = 12'd2;                // 框线宽（像素）

  // ★ P6 新增：AE 闭环状态行（16 槽 x 16 = 256x16）
  //   格式： `A 07C6 G 59 L 6E`  共 16 槽
  //         [0]    'A'(自动) / 'M'(手动)
  //         [2:5]  曝光值 4 位十六进制（上限 1990 = 0x7C6）
  //         [7]    'G'
  //         [9:10] 模拟增益 2 位十六进制（16~89，十进制 89 = 0x59）
  //         [12]   'L'
  //         [14:15]平均亮度 2 位十六进制（0x00~0xFF）
  //   ★ 为什么用十六进制：**纯位切片 ⇒ 零比较链 ⇒ 不压 HDMI 域时序**。
  //     交付版 SWNS 只剩 +0.304 ns，HDMI 域是最紧的域，任何除法/比较链
  //     都可能把它压到负值（P3 的 LATENCY 除法链就是反面教材）。
  //   ★ 位置 (256,144)：与既有 6 个区域均不重叠 ——
  //       Logo(7..152, 34..127) 列不相交；延迟文本(256,48..63)、
  //       目标文字(256,80..95) 行不相交；动态 CNT(375..574, 120..143) 行不相交
  //       （本区从 144 行开始，正好贴在其下沿之下）。
  //     校验：python tools\verify_osd_layout.py
  localparam AEINFO_X = 12'd256;
  localparam AEINFO_Y = 12'd144;
  //  ★ 2026-09-27：16 槽 -> **24 槽**，行尾追加 ` K xxxxx`（本帧过曝像素数）。
  //    目的：一次分开"高光保护抑制了加亮"与"提交路径有问题"两条岔路。
  //    该信号（I_ae_clip）本来就存在于端口上、一直没接到任何槽位。
  localparam AEINFO_W = 12'd384;               // 24 槽 x 16
  localparam AEINFO_H = 12'd16;
  localparam COLOR_AE = 24'h40c0ff;            // AE 文字：天蓝，与琥珀/亮绿区分

  // ★ 2026-09-26 新增：**目标坐标行**（进阶要求②"动态目标跟踪与坐标叠加"）
  //   区域 (256,176)：在 AE 行(y=144..159)之下，与既有 7 个区域都不重叠。
  //   格式 `BLK 0312,0208`（13 槽有效，其余补空格）。
  //   十进制位**已在 ISP 域算好**（O_tgt_x_d*/O_tgt_y_d*），本域只做"槽位→字符码"查表，
  //   ⇒ 不在像素率路径上引入除法/比较链（P3 的 LATENCY 除法链就是反面教材）。
  localparam TGTPOS_X = 12'd256;
  localparam TGTPOS_Y = 12'd176;
  localparam TGTPOS_W = 12'd256;               // 16 槽 x 16
  localparam TGTPOS_H = 12'd16;
  localparam COLOR_TGTPOS = 24'hffd040;        // 与目标文字同色（琥珀），语义一致

  // ★ P7 新增：运动框（颜色刻意与目标框区分）+ 运动计数行
  //   运动框用**青色**：红色是"颜色目标框"，青色是"运动区域"，一眼可分。
  localparam COLOR_MBOX = 24'h00d0ff;
  localparam MOTBOX_T   = 12'd2;
  //   计数行 (256,208)：在目标坐标行(y=176..191)之下，与既有 8 个区域都不重叠。
  //   ★ 这一行用**十六进制**（与 P5 诊断行同理）：纯位切片 ⇒ 零比较链 ⇒ 不压时序。
  //     坐标行用十进制是**赛题要求**（坐标要给人读），运动计数是**辅助读数**，
  //     二者取舍不同，故格式不同 —— 这一点在报告里写明。
  localparam MOTINFO_X = 12'd256;
  localparam MOTINFO_Y = 12'd208;
  localparam MOTINFO_W = 12'd256;
  localparam MOTINFO_H = 12'd16;
  localparam COLOR_MOT = 24'h00d0ff;

    localparam COLOR_MODE_ON  = 24'h00ff40;     // 亮绿
    localparam COLOR_MODE_OFF = 24'h002010;     // 暗绿底

    // ★★ 临时诊断用：4 bit → 十六进制字符码（'0'-'9','A'-'F'）
    //   用十六进制是为了**零额外逻辑**：不需要比较链/除法，纯位切片。
    //   字库里大写 A-Z 与 0-9 都有，直接可用。
    function [7:0] hexdig;
        input [3:0] d;
        begin
            if (d < 4'd10) hexdig = 8'h30 + {4'd0, d};        // '0'..'9'
            else           hexdig = 8'h41 + {4'd0, d} - 8'd10; // 'A'..'F'
        end
    endfunction

    // mode[2:0] -> 7 段码 {a,b,c,d,e,f,g}（与工程内 F_hex7seg 同序）
    //   P4：模式扩到 5 个（0..4），故这里补全 0..9，模式 4 显示 "4"。
    function [6:0] F_mode7seg;
        input [3:0] I_val;
        begin
            case(I_val)
                4'd0: F_mode7seg = 7'b1111110;
                4'd1: F_mode7seg = 7'b0110000;
                4'd2: F_mode7seg = 7'b1101101;
                4'd3: F_mode7seg = 7'b1111001;
                4'd4: F_mode7seg = 7'b0110011;
                4'd5: F_mode7seg = 7'b1011011;
                4'd6: F_mode7seg = 7'b1011111;
                4'd7: F_mode7seg = 7'b1110000;
                4'd8: F_mode7seg = 7'b1111111;
                4'd9: F_mode7seg = 7'b1111011;
                default: F_mode7seg = 7'b0000000;
            endcase
        end
    endfunction

    function [4:0] F_logo_text_bits;
        input [3:0] I_char;
        input [2:0] I_row;
        begin
            case(I_char)
                4'd0: begin
                    case(I_row) // A
                        3'd0: F_logo_text_bits = 5'b01110;
                        3'd1: F_logo_text_bits = 5'b10001;
                        3'd2: F_logo_text_bits = 5'b10001;
                        3'd3: F_logo_text_bits = 5'b11111;
                        3'd4: F_logo_text_bits = 5'b10001;
                        3'd5: F_logo_text_bits = 5'b10001;
                        3'd6: F_logo_text_bits = 5'b10001;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                4'd1: begin
                    case(I_row) // N
                        3'd0: F_logo_text_bits = 5'b10001;
                        3'd1: F_logo_text_bits = 5'b11001;
                        3'd2: F_logo_text_bits = 5'b10101;
                        3'd3: F_logo_text_bits = 5'b10011;
                        3'd4: F_logo_text_bits = 5'b10001;
                        3'd5: F_logo_text_bits = 5'b10001;
                        3'd6: F_logo_text_bits = 5'b10001;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                4'd2: begin
                    case(I_row) // L
                        3'd0: F_logo_text_bits = 5'b10000;
                        3'd1: F_logo_text_bits = 5'b10000;
                        3'd2: F_logo_text_bits = 5'b10000;
                        3'd3: F_logo_text_bits = 5'b10000;
                        3'd4: F_logo_text_bits = 5'b10000;
                        3'd5: F_logo_text_bits = 5'b10000;
                        3'd6: F_logo_text_bits = 5'b11111;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                4'd3: begin
                    case(I_row) // O
                        3'd0: F_logo_text_bits = 5'b01110;
                        3'd1: F_logo_text_bits = 5'b10001;
                        3'd2: F_logo_text_bits = 5'b10001;
                        3'd3: F_logo_text_bits = 5'b10001;
                        3'd4: F_logo_text_bits = 5'b10001;
                        3'd5: F_logo_text_bits = 5'b10001;
                        3'd6: F_logo_text_bits = 5'b01110;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                4'd4: begin
                    case(I_row) // G
                        3'd0: F_logo_text_bits = 5'b01110;
                        3'd1: F_logo_text_bits = 5'b10001;
                        3'd2: F_logo_text_bits = 5'b10000;
                        3'd3: F_logo_text_bits = 5'b10111;
                        3'd4: F_logo_text_bits = 5'b10001;
                        3'd5: F_logo_text_bits = 5'b10001;
                        3'd6: F_logo_text_bits = 5'b01110;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                4'd5: begin
                    case(I_row) // I
                        3'd0: F_logo_text_bits = 5'b11111;
                        3'd1: F_logo_text_bits = 5'b00100;
                        3'd2: F_logo_text_bits = 5'b00100;
                        3'd3: F_logo_text_bits = 5'b00100;
                        3'd4: F_logo_text_bits = 5'b00100;
                        3'd5: F_logo_text_bits = 5'b00100;
                        3'd6: F_logo_text_bits = 5'b11111;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                4'd6: begin
                    case(I_row) // C
                        3'd0: F_logo_text_bits = 5'b01110;
                        3'd1: F_logo_text_bits = 5'b10001;
                        3'd2: F_logo_text_bits = 5'b10000;
                        3'd3: F_logo_text_bits = 5'b10000;
                        3'd4: F_logo_text_bits = 5'b10000;
                        3'd5: F_logo_text_bits = 5'b10001;
                        3'd6: F_logo_text_bits = 5'b01110;
                        default: F_logo_text_bits = 5'b00000;
                    endcase
                end
                default: F_logo_text_bits = 5'b00000;
            endcase
        end
    endfunction

    // 7-seg bit mapping: {a,b,c,d,e,f,g}
    function [6:0] F_hex7seg;
        input [3:0] I_hex;
        begin
            case(I_hex)
                4'h0: F_hex7seg = 7'b1111110;
                4'h1: F_hex7seg = 7'b0110000;
                4'h2: F_hex7seg = 7'b1101101;
                4'h3: F_hex7seg = 7'b1111001;
                4'h4: F_hex7seg = 7'b0110011;
                4'h5: F_hex7seg = 7'b1011011;
                4'h6: F_hex7seg = 7'b1011111;
                4'h7: F_hex7seg = 7'b1110000;
                4'h8: F_hex7seg = 7'b1111111;
                4'h9: F_hex7seg = 7'b1111011;
                4'ha: F_hex7seg = 7'b1110111;
                4'hb: F_hex7seg = 7'b0011111;
                4'hc: F_hex7seg = 7'b1001110;
                4'hd: F_hex7seg = 7'b0111101;
                4'he: F_hex7seg = 7'b1001111;
                4'hf: F_hex7seg = 7'b1000111;
                default: F_hex7seg = 7'b0000000;
            endcase
        end
    endfunction

    function [4:0] F_cnt_label_bits;
        input [1:0] I_idx;
        input [2:0] I_row;
        begin
            case(I_idx)
                2'd0: begin // C
                    case(I_row)
                        3'd0: F_cnt_label_bits = 5'b01110;
                        3'd1: F_cnt_label_bits = 5'b10001;
                        3'd2: F_cnt_label_bits = 5'b10000;
                        3'd3: F_cnt_label_bits = 5'b10000;
                        3'd4: F_cnt_label_bits = 5'b10000;
                        3'd5: F_cnt_label_bits = 5'b10001;
                        3'd6: F_cnt_label_bits = 5'b01110;
                        default: F_cnt_label_bits = 5'b00000;
                    endcase
                end
                2'd1: begin // N
                    case(I_row)
                        3'd0: F_cnt_label_bits = 5'b10001;
                        3'd1: F_cnt_label_bits = 5'b11001;
                        3'd2: F_cnt_label_bits = 5'b10101;
                        3'd3: F_cnt_label_bits = 5'b10011;
                        3'd4: F_cnt_label_bits = 5'b10001;
                        3'd5: F_cnt_label_bits = 5'b10001;
                        3'd6: F_cnt_label_bits = 5'b10001;
                        default: F_cnt_label_bits = 5'b00000;
                    endcase
                end
                2'd2: begin // T
                    case(I_row)
                        3'd0: F_cnt_label_bits = 5'b11111;
                        3'd1: F_cnt_label_bits = 5'b00100;
                        3'd2: F_cnt_label_bits = 5'b00100;
                        3'd3: F_cnt_label_bits = 5'b00100;
                        3'd4: F_cnt_label_bits = 5'b00100;
                        3'd5: F_cnt_label_bits = 5'b00100;
                        3'd6: F_cnt_label_bits = 5'b00100;
                        default: F_cnt_label_bits = 5'b00000;
                    endcase
                end
                default: begin // ':'
                    case(I_row)
                        3'd2: F_cnt_label_bits = 5'b00100;
                        3'd5: F_cnt_label_bits = 5'b00100;
                        default: F_cnt_label_bits = 5'b00000;
                    endcase
                end
            endcase
        end
    endfunction

    // Minimal 16x16 Chinese bitmap rows for "an" and "lu".
    function [15:0] F_cn16_row;
        input I_char; // 0: an, 1: lu
        input [3:0] I_row;
        begin
            if(!I_char) begin
                case(I_row)
                    4'd0:  F_cn16_row = 16'h0200;
                    4'd1:  F_cn16_row = 16'h7ff0;
                    4'd2:  F_cn16_row = 16'h4410;
                    4'd3:  F_cn16_row = 16'h0400;
                    4'd4:  F_cn16_row = 16'h7ff0;
                    4'd5:  F_cn16_row = 16'h0840;
                    4'd6:  F_cn16_row = 16'h1040;
                    4'd7:  F_cn16_row = 16'h1c80;
                    4'd8:  F_cn16_row = 16'h0300;
                    4'd9:  F_cn16_row = 16'h0cc0;
                    4'd10: F_cn16_row = 16'h7020;
                    4'd11: F_cn16_row = 16'h0000;
                    4'd12: F_cn16_row = 16'h0000;
                    4'd13: F_cn16_row = 16'h0000;
                    4'd14: F_cn16_row = 16'h0000;
                    4'd15: F_cn16_row = 16'h0000;
                    default: F_cn16_row = 16'h0000;
                endcase
            end
            else begin
                case(I_row)
                    4'd0:  F_cn16_row = 16'h79e0;
                    4'd1:  F_cn16_row = 16'h4a20;
                    4'd2:  F_cn16_row = 16'h4d40;
                    4'd3:  F_cn16_row = 16'h7880;
                    4'd4:  F_cn16_row = 16'h1140;
                    4'd5:  F_cn16_row = 16'h1630;
                    4'd6:  F_cn16_row = 16'h5be0;
                    4'd7:  F_cn16_row = 16'h5220;
                    4'd8:  F_cn16_row = 16'h5220;
                    4'd9:  F_cn16_row = 16'h5be0;
                    4'd10: F_cn16_row = 16'h6220;
                    4'd11: F_cn16_row = 16'h0000;
                    4'd12: F_cn16_row = 16'h0000;
                    4'd13: F_cn16_row = 16'h0000;
                    4'd14: F_cn16_row = 16'h0000;
                    4'd15: F_cn16_row = 16'h0000;
                    default: F_cn16_row = 16'h0000;
                endcase
            end
        end
    endfunction

    function [4:0] F_dyn_char_bits;
        input [3:0] I_char;
        input [2:0] I_row;
        begin
            case(I_char)
                4'h0: begin case(I_row) 3'd0:F_dyn_char_bits=5'b01110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10011; 3'd3:F_dyn_char_bits=5'b10101; 3'd4:F_dyn_char_bits=5'b11001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b01110; default:F_dyn_char_bits=5'b00000; endcase end
                4'h1: begin case(I_row) 3'd0:F_dyn_char_bits=5'b00100; 3'd1:F_dyn_char_bits=5'b01100; 3'd2:F_dyn_char_bits=5'b00100; 3'd3:F_dyn_char_bits=5'b00100; 3'd4:F_dyn_char_bits=5'b00100; 3'd5:F_dyn_char_bits=5'b00100; 3'd6:F_dyn_char_bits=5'b01110; default:F_dyn_char_bits=5'b00000; endcase end
                4'h2: begin case(I_row) 3'd0:F_dyn_char_bits=5'b01110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b00001; 3'd3:F_dyn_char_bits=5'b00110; 3'd4:F_dyn_char_bits=5'b01000; 3'd5:F_dyn_char_bits=5'b10000; 3'd6:F_dyn_char_bits=5'b11111; default:F_dyn_char_bits=5'b00000; endcase end
                4'h3: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11110; 3'd1:F_dyn_char_bits=5'b00001; 3'd2:F_dyn_char_bits=5'b00001; 3'd3:F_dyn_char_bits=5'b01110; 3'd4:F_dyn_char_bits=5'b00001; 3'd5:F_dyn_char_bits=5'b00001; 3'd6:F_dyn_char_bits=5'b11110; default:F_dyn_char_bits=5'b00000; endcase end
                4'h4: begin case(I_row) 3'd0:F_dyn_char_bits=5'b00010; 3'd1:F_dyn_char_bits=5'b00110; 3'd2:F_dyn_char_bits=5'b01010; 3'd3:F_dyn_char_bits=5'b10010; 3'd4:F_dyn_char_bits=5'b11111; 3'd5:F_dyn_char_bits=5'b00010; 3'd6:F_dyn_char_bits=5'b00010; default:F_dyn_char_bits=5'b00000; endcase end
                4'h5: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11111; 3'd1:F_dyn_char_bits=5'b10000; 3'd2:F_dyn_char_bits=5'b11110; 3'd3:F_dyn_char_bits=5'b00001; 3'd4:F_dyn_char_bits=5'b00001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b01110; default:F_dyn_char_bits=5'b00000; endcase end
                4'h6: begin case(I_row) 3'd0:F_dyn_char_bits=5'b00110; 3'd1:F_dyn_char_bits=5'b01000; 3'd2:F_dyn_char_bits=5'b10000; 3'd3:F_dyn_char_bits=5'b11110; 3'd4:F_dyn_char_bits=5'b10001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b01110; default:F_dyn_char_bits=5'b00000; endcase end
                4'h7: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11111; 3'd1:F_dyn_char_bits=5'b00001; 3'd2:F_dyn_char_bits=5'b00010; 3'd3:F_dyn_char_bits=5'b00100; 3'd4:F_dyn_char_bits=5'b01000; 3'd5:F_dyn_char_bits=5'b01000; 3'd6:F_dyn_char_bits=5'b01000; default:F_dyn_char_bits=5'b00000; endcase end
                4'h8: begin case(I_row) 3'd0:F_dyn_char_bits=5'b01110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10001; 3'd3:F_dyn_char_bits=5'b01110; 3'd4:F_dyn_char_bits=5'b10001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b01110; default:F_dyn_char_bits=5'b00000; endcase end
                4'h9: begin case(I_row) 3'd0:F_dyn_char_bits=5'b01110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10001; 3'd3:F_dyn_char_bits=5'b01111; 3'd4:F_dyn_char_bits=5'b00001; 3'd5:F_dyn_char_bits=5'b00010; 3'd6:F_dyn_char_bits=5'b11100; default:F_dyn_char_bits=5'b00000; endcase end
                4'ha: begin case(I_row) 3'd0:F_dyn_char_bits=5'b01110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10001; 3'd3:F_dyn_char_bits=5'b11111; 3'd4:F_dyn_char_bits=5'b10001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b10001; default:F_dyn_char_bits=5'b00000; endcase end
                4'hb: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10001; 3'd3:F_dyn_char_bits=5'b11110; 3'd4:F_dyn_char_bits=5'b10001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b11110; default:F_dyn_char_bits=5'b00000; endcase end
                4'hc: begin case(I_row) 3'd0:F_dyn_char_bits=5'b01110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10000; 3'd3:F_dyn_char_bits=5'b10000; 3'd4:F_dyn_char_bits=5'b10000; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b01110; default:F_dyn_char_bits=5'b00000; endcase end
                4'hd: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11110; 3'd1:F_dyn_char_bits=5'b10001; 3'd2:F_dyn_char_bits=5'b10001; 3'd3:F_dyn_char_bits=5'b10001; 3'd4:F_dyn_char_bits=5'b10001; 3'd5:F_dyn_char_bits=5'b10001; 3'd6:F_dyn_char_bits=5'b11110; default:F_dyn_char_bits=5'b00000; endcase end
                4'he: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11111; 3'd1:F_dyn_char_bits=5'b10000; 3'd2:F_dyn_char_bits=5'b10000; 3'd3:F_dyn_char_bits=5'b11110; 3'd4:F_dyn_char_bits=5'b10000; 3'd5:F_dyn_char_bits=5'b10000; 3'd6:F_dyn_char_bits=5'b11111; default:F_dyn_char_bits=5'b00000; endcase end
                4'hf: begin case(I_row) 3'd0:F_dyn_char_bits=5'b11111; 3'd1:F_dyn_char_bits=5'b10000; 3'd2:F_dyn_char_bits=5'b10000; 3'd3:F_dyn_char_bits=5'b11110; 3'd4:F_dyn_char_bits=5'b10000; 3'd5:F_dyn_char_bits=5'b10000; 3'd6:F_dyn_char_bits=5'b10000; default:F_dyn_char_bits=5'b00000; endcase end
                default: F_dyn_char_bits = 5'b00000;
            endcase
        end
    endfunction

    // Unified prefix character library (16x16 rows): an/lu/C/N/T/:
    function [15:0] F_osd_char16_row;
        input [7:0] I_char;
        input [3:0] I_row;
        begin
            case(I_char)
                CHAR_AN: begin
                    case(I_row)
                        4'd0:  F_osd_char16_row = 16'h0200;
                        4'd1:  F_osd_char16_row = 16'h7ff0;
                        4'd2:  F_osd_char16_row = 16'h4410;
                        4'd3:  F_osd_char16_row = 16'h0400;
                        4'd4:  F_osd_char16_row = 16'h7ff0;
                        4'd5:  F_osd_char16_row = 16'h0840;
                        4'd6:  F_osd_char16_row = 16'h1040;
                        4'd7:  F_osd_char16_row = 16'h1c80;
                        4'd8:  F_osd_char16_row = 16'h0300;
                        4'd9:  F_osd_char16_row = 16'h0cc0;
                        4'd10: F_osd_char16_row = 16'h7020;
                        default: F_osd_char16_row = 16'h0000;
                    endcase
                end
                CHAR_LU: begin
                    case(I_row)
                        4'd0:  F_osd_char16_row = 16'h79e0;
                        4'd1:  F_osd_char16_row = 16'h4a20;
                        4'd2:  F_osd_char16_row = 16'h4d40;
                        4'd3:  F_osd_char16_row = 16'h7880;
                        4'd4:  F_osd_char16_row = 16'h1140;
                        4'd5:  F_osd_char16_row = 16'h1630;
                        4'd6:  F_osd_char16_row = 16'h5be0;
                        4'd7:  F_osd_char16_row = 16'h5220;
                        4'd8:  F_osd_char16_row = 16'h5220;
                        4'd9:  F_osd_char16_row = 16'h5be0;
                        4'd10: F_osd_char16_row = 16'h6220;
                        default: F_osd_char16_row = 16'h0000;
                    endcase
                end
                CHAR_C: begin
                    case(I_row)
                        4'd2:  F_osd_char16_row = 16'h03f0;
                        4'd3:  F_osd_char16_row = 16'h0c0c;
                        4'd4:  F_osd_char16_row = 16'h1800;
                        4'd5:  F_osd_char16_row = 16'h3000;
                        4'd6:  F_osd_char16_row = 16'h3000;
                        4'd7:  F_osd_char16_row = 16'h3000;
                        4'd8:  F_osd_char16_row = 16'h3000;
                        4'd9:  F_osd_char16_row = 16'h3000;
                        4'd10: F_osd_char16_row = 16'h1800;
                        4'd11: F_osd_char16_row = 16'h0c0c;
                        4'd12: F_osd_char16_row = 16'h03f0;
                        default: F_osd_char16_row = 16'h0000;
                    endcase
                end
                CHAR_N: begin
                    case(I_row)
                        4'd2:  F_osd_char16_row = 16'h300c;
                        4'd3:  F_osd_char16_row = 16'h380c;
                        4'd4:  F_osd_char16_row = 16'h3c0c;
                        4'd5:  F_osd_char16_row = 16'h360c;
                        4'd6:  F_osd_char16_row = 16'h330c;
                        4'd7:  F_osd_char16_row = 16'h318c;
                        4'd8:  F_osd_char16_row = 16'h30cc;
                        4'd9:  F_osd_char16_row = 16'h306c;
                        4'd10: F_osd_char16_row = 16'h303c;
                        4'd11: F_osd_char16_row = 16'h301c;
                        4'd12: F_osd_char16_row = 16'h300c;
                        default: F_osd_char16_row = 16'h0000;
                    endcase
                end
                CHAR_T: begin
                    case(I_row)
                        4'd2:  F_osd_char16_row = 16'h3ffc;
                        4'd3:  F_osd_char16_row = 16'h03c0;
                        4'd4:  F_osd_char16_row = 16'h03c0;
                        4'd5:  F_osd_char16_row = 16'h03c0;
                        4'd6:  F_osd_char16_row = 16'h03c0;
                        4'd7:  F_osd_char16_row = 16'h03c0;
                        4'd8:  F_osd_char16_row = 16'h03c0;
                        4'd9:  F_osd_char16_row = 16'h03c0;
                        4'd10: F_osd_char16_row = 16'h03c0;
                        4'd11: F_osd_char16_row = 16'h03c0;
                        4'd12: F_osd_char16_row = 16'h03c0;
                        default: F_osd_char16_row = 16'h0000;
                    endcase
                end
                CHAR_COLON: begin
                    case(I_row)
                        4'd6:  F_osd_char16_row = 16'h0180;
                        4'd7:  F_osd_char16_row = 16'h0180;
                        4'd10: F_osd_char16_row = 16'h0180;
                        4'd11: F_osd_char16_row = 16'h0180;
                        default: F_osd_char16_row = 16'h0000;
                    endcase
                end
                default: F_osd_char16_row = 16'h0000;
            endcase
        end
    endfunction

    assign O_video_rd_en = I_video_de;

  // ==========================================================================
  // ★ P3：显示帧起始脉冲（供 frame_latency 统计"已经显示到第几帧"）
  //   用**输出侧**的 O_hdmi_vsync（已打两拍）的上升沿，与被显示的那一帧严格对齐。
  // ==========================================================================
  always @(posedge I_clk or negedge I_rst_n) begin
      if(!I_rst_n)
          S_vsync_d <= 1'b0;
      else
          S_vsync_d <= O_hdmi_vsync;
  end
  assign O_dis_frame_start = O_hdmi_vsync & ~S_vsync_d;

  // ==========================================================================
  // ★ P3：十进制转换的**流水寄存器级**
  // --------------------------------------------------------------------------
  //  S_lat_d1/d2/d3 是纯组合算出来的（含一次 /100），若直接送去索引
  //  osd_char_lib（77 字形的组合大表）再进输出 mux，HDMI_PIXEL_CLK 域会出现
  //  17 级逻辑、SWNS 仅剩 0.344 ns（实测）。
  //  这里把结果打一拍再交给字符选择逻辑，相当于在长链中间插入一级流水。
  //  延迟值每帧才更新一次，**加这一拍对显示完全无损**。
  // ==========================================================================
  always @(posedge I_clk or negedge I_rst_n) begin
      if(!I_rst_n) begin
          S_lat_d1_r    <= 4'd10;
          S_lat_d2_r    <= 4'd10;
          S_lat_d3_r    <= 4'd10;
          S_lat_valid_r <= 1'b0;
      end else begin
          S_lat_d1_r    <= S_lat_d1;
          S_lat_d2_r    <= S_lat_d2;
          S_lat_d3_r    <= S_lat_d3;
          S_lat_valid_r <= I_lat_valid;
      end
  end

    // [P1b] old: anlogic_logo_rom (combinational case) -> LUT mesh
    //        new: logo_rom_eram (synchronous read, infers ERAM), +1 cycle latency
    logo_rom_eram u_logo_rom_eram(
        .I_clk   ( I_clk         ),
        .I_rst_n ( I_rst_n       ),
        .I_addr  ( S_logo_addr14 ),
        .O_idx   ( S_logo_idx    )
    );

    // ========================================================================
    // [P1b] Logo palette: 8-bit index -> 24-bit RGB
    //   generated by tools/gen_logo_rom_v.py from tools/logo_rom/logo_palette.vh
    //   index 0 = transparent (caller treats it as "no Logo pixel")
    //   256 entries, purely combinational - far cheaper than the old
    //   25-bit x 16384 combinational ROM it replaces.
    // ========================================================================
    function [23:0] logo_palette_rom;
        input [7:0] I_idx;
        begin
            case (I_idx)
                8'd0: logo_palette_rom = 24'h000000;
                8'd1: logo_palette_rom = 24'h1c2d4e;
                8'd2: logo_palette_rom = 24'h1c2d4f;
                8'd3: logo_palette_rom = 24'h1c2e4f;
                8'd4: logo_palette_rom = 24'h1d2e4f;
                8'd5: logo_palette_rom = 24'h1d2e4e;
                8'd6: logo_palette_rom = 24'h1d2e50;
                8'd7: logo_palette_rom = 24'h1e2f50;
                8'd8: logo_palette_rom = 24'h1e2f51;
                8'd9: logo_palette_rom = 24'h1f2f50;
                8'd10: logo_palette_rom = 24'h1f3051;
                8'd11: logo_palette_rom = 24'h1f3050;
                8'd12: logo_palette_rom = 24'h203050;
                8'd13: logo_palette_rom = 24'h203051;
                8'd14: logo_palette_rom = 24'h203151;
                8'd15: logo_palette_rom = 24'h203152;
                8'd16: logo_palette_rom = 24'hed1c24;
                8'd17: logo_palette_rom = 24'hee1c24;
                8'd18: logo_palette_rom = 24'h213152;
                8'd19: logo_palette_rom = 24'h213252;
                8'd20: logo_palette_rom = 24'h213253;
                8'd21: logo_palette_rom = 24'h223253;
                8'd22: logo_palette_rom = 24'h223353;
                8'd23: logo_palette_rom = 24'h223354;
                8'd24: logo_palette_rom = 24'h233353;
                8'd25: logo_palette_rom = 24'h233454;
                8'd26: logo_palette_rom = 24'h243453;
                8'd27: logo_palette_rom = 24'h243555;
                8'd28: logo_palette_rom = 24'h253555;
                8'd29: logo_palette_rom = 24'h253656;
                8'd30: logo_palette_rom = 24'h263656;
                8'd31: logo_palette_rom = 24'h263757;
                8'd32: logo_palette_rom = 24'h283858;
                8'd33: logo_palette_rom = 24'h293958;
                8'd34: logo_palette_rom = 24'h2a3958;
                8'd35: logo_palette_rom = 24'h2a3a59;
                8'd36: logo_palette_rom = 24'h2b3b59;
                8'd37: logo_palette_rom = 24'h2c3b5a;
                8'd38: logo_palette_rom = 24'h2c3c5a;
                8'd39: logo_palette_rom = 24'h2d3d5b;
                8'd40: logo_palette_rom = 24'h2f3e5c;
                8'd41: logo_palette_rom = 24'h303f5d;
                8'd42: logo_palette_rom = 24'h31405e;
                8'd43: logo_palette_rom = 24'h32415f;
                8'd44: logo_palette_rom = 24'h32425f;
                8'd45: logo_palette_rom = 24'h334260;
                8'd46: logo_palette_rom = 24'h334360;
                8'd47: logo_palette_rom = 24'h344360;
                8'd48: logo_palette_rom = 24'h344461;
                8'd49: logo_palette_rom = 24'h354360;
                8'd50: logo_palette_rom = 24'h354461;
                8'd51: logo_palette_rom = 24'h364461;
                8'd52: logo_palette_rom = 24'h364562;
                8'd53: logo_palette_rom = 24'h374562;
                8'd54: logo_palette_rom = 24'h374663;
                8'd55: logo_palette_rom = 24'h384663;
                8'd56: logo_palette_rom = 24'h394763;
                8'd57: logo_palette_rom = 24'h394764;
                8'd58: logo_palette_rom = 24'h394864;
                8'd59: logo_palette_rom = 24'h3a4864;
                8'd60: logo_palette_rom = 24'h3b4965;
                8'd61: logo_palette_rom = 24'h3c4a65;
                8'd62: logo_palette_rom = 24'h3d4a66;
                8'd63: logo_palette_rom = 24'h3e4c68;
                8'd64: logo_palette_rom = 24'h404e69;
                8'd65: logo_palette_rom = 24'h424f6a;
                8'd66: logo_palette_rom = 24'h43506a;
                8'd67: logo_palette_rom = 24'h43516c;
                8'd68: logo_palette_rom = 24'h45526c;
                8'd69: logo_palette_rom = 24'h47546e;
                8'd70: logo_palette_rom = 24'h48556f;
                8'd71: logo_palette_rom = 24'h4a5771;
                8'd72: logo_palette_rom = 24'h4d5972;
                8'd73: logo_palette_rom = 24'h4e5b73;
                8'd74: logo_palette_rom = 24'h4f5b74;
                8'd75: logo_palette_rom = 24'h505c75;
                8'd76: logo_palette_rom = 24'h535e76;
                8'd77: logo_palette_rom = 24'h546078;
                8'd78: logo_palette_rom = 24'h57627a;
                8'd79: logo_palette_rom = 24'h58647c;
                8'd80: logo_palette_rom = 24'h5b6579;
                8'd81: logo_palette_rom = 24'hee1d25;
                8'd82: logo_palette_rom = 24'hef1c24;
                8'd83: logo_palette_rom = 24'h5b657b;
                8'd84: logo_palette_rom = 24'h5b677d;
                8'd85: logo_palette_rom = 24'h5f697f;
                8'd86: logo_palette_rom = 24'h606a80;
                8'd87: logo_palette_rom = 24'h616c82;
                8'd88: logo_palette_rom = 24'h636e84;
                8'd89: logo_palette_rom = 24'h666f84;
                8'd90: logo_palette_rom = 24'h677186;
                8'd91: logo_palette_rom = 24'h697388;
                8'd92: logo_palette_rom = 24'h6c768a;
                8'd93: logo_palette_rom = 24'h6e7688;
                8'd94: logo_palette_rom = 24'h6f788c;
                8'd95: logo_palette_rom = 24'h707a8d;
                8'd96: logo_palette_rom = 24'h707a8e;
                8'd97: logo_palette_rom = 24'h717b8e;
                8'd98: logo_palette_rom = 24'h727b8f;
                8'd99: logo_palette_rom = 24'h727c8f;
                8'd100: logo_palette_rom = 24'h737c90;
                8'd101: logo_palette_rom = 24'h737d90;
                8'd102: logo_palette_rom = 24'h747e90;
                8'd103: logo_palette_rom = 24'h757e91;
                8'd104: logo_palette_rom = 24'h767f91;
                8'd105: logo_palette_rom = 24'h778092;
                8'd106: logo_palette_rom = 24'h788092;
                8'd107: logo_palette_rom = 24'h798193;
                8'd108: logo_palette_rom = 24'h798294;
                8'd109: logo_palette_rom = 24'h7a8394;
                8'd110: logo_palette_rom = 24'h7b8495;
                8'd111: logo_palette_rom = 24'h7c8596;
                8'd112: logo_palette_rom = 24'h7d8596;
                8'd113: logo_palette_rom = 24'h7e8697;
                8'd114: logo_palette_rom = 24'h7f8798;
                8'd115: logo_palette_rom = 24'h7f8798;
                8'd116: logo_palette_rom = 24'h808899;
                8'd117: logo_palette_rom = 24'h818999;
                8'd118: logo_palette_rom = 24'h838999;
                8'd119: logo_palette_rom = 24'h848c9c;
                8'd120: logo_palette_rom = 24'h868d9d;
                8'd121: logo_palette_rom = 24'h8a8f9e;
                8'd122: logo_palette_rom = 24'h8a91a0;
                8'd123: logo_palette_rom = 24'h8b93a2;
                8'd124: logo_palette_rom = 24'h8d94a3;
                8'd125: logo_palette_rom = 24'h8e95a3;
                8'd126: logo_palette_rom = 24'h8f96a4;
                8'd127: logo_palette_rom = 24'h9197a6;
                8'd128: logo_palette_rom = 24'h959ba9;
                8'd129: logo_palette_rom = 24'h969daa;
                8'd130: logo_palette_rom = 24'h989eab;
                8'd131: logo_palette_rom = 24'h999fac;
                8'd132: logo_palette_rom = 24'h9aa0ae;
                8'd133: logo_palette_rom = 24'h9ca2ae;
                8'd134: logo_palette_rom = 24'ha0a6b2;
                8'd135: logo_palette_rom = 24'ha3a9b4;
                8'd136: logo_palette_rom = 24'ha6abb6;
                8'd137: logo_palette_rom = 24'ha8adb8;
                8'd138: logo_palette_rom = 24'habb0ba;
                8'd139: logo_palette_rom = 24'haeb3bd;
                8'd140: logo_palette_rom = 24'hb2b7c0;
                8'd141: logo_palette_rom = 24'hb6bac2;
                8'd142: logo_palette_rom = 24'hb8bcc5;
                8'd143: logo_palette_rom = 24'hbbbfc7;
                8'd144: logo_palette_rom = 24'hc0c3cb;
                8'd145: logo_palette_rom = 24'hc1c5cc;
                8'd146: logo_palette_rom = 24'hc2c6cd;
                8'd147: logo_palette_rom = 24'hc3c7ce;
                8'd148: logo_palette_rom = 24'hc4c7ce;
                8'd149: logo_palette_rom = 24'hc5c8cf;
                8'd150: logo_palette_rom = 24'hc6c9d0;
                8'd151: logo_palette_rom = 24'hc7cad0;
                8'd152: logo_palette_rom = 24'hc8cbd1;
                8'd153: logo_palette_rom = 24'hc9ccd2;
                8'd154: logo_palette_rom = 24'hcacdd3;
                8'd155: logo_palette_rom = 24'hcbced4;
                8'd156: logo_palette_rom = 24'hccced4;
                8'd157: logo_palette_rom = 24'hcccfd5;
                8'd158: logo_palette_rom = 24'hcdcfd5;
                8'd159: logo_palette_rom = 24'hd0d2d7;
                8'd160: logo_palette_rom = 24'hd2d4d9;
                8'd161: logo_palette_rom = 24'hd3d6da;
                8'd162: logo_palette_rom = 24'hd6d7dc;
                8'd163: logo_palette_rom = 24'hd7d9dd;
                8'd164: logo_palette_rom = 24'hd8dade;
                8'd165: logo_palette_rom = 24'hd9dadf;
                8'd166: logo_palette_rom = 24'hdbdce0;
                8'd167: logo_palette_rom = 24'hdddee2;
                8'd168: logo_palette_rom = 24'hdfe1e4;
                8'd169: logo_palette_rom = 24'he1e3e6;
                8'd170: logo_palette_rom = 24'he3e4e7;
                8'd171: logo_palette_rom = 24'he6e7e9;
                8'd172: logo_palette_rom = 24'he8e9eb;
                8'd173: logo_palette_rom = 24'he9eaec;
                8'd174: logo_palette_rom = 24'heaeaed;
                8'd175: logo_palette_rom = 24'hf01c25;
                8'd176: logo_palette_rom = 24'hef1d25;
                8'd177: logo_palette_rom = 24'hef1e26;
                8'd178: logo_palette_rom = 24'hf01c25;
                8'd179: logo_palette_rom = 24'hf11d25;
                8'd180: logo_palette_rom = 24'hf01e26;
                8'd181: logo_palette_rom = 24'hef2027;
                8'd182: logo_palette_rom = 24'hf01f27;
                8'd183: logo_palette_rom = 24'hf12028;
                8'd184: logo_palette_rom = 24'hf12027;
                8'd185: logo_palette_rom = 24'hf21f27;
                8'd186: logo_palette_rom = 24'hef2129;
                8'd187: logo_palette_rom = 24'hf12129;
                8'd188: logo_palette_rom = 24'hf1222a;
                8'd189: logo_palette_rom = 24'hf2222a;
                8'd190: logo_palette_rom = 24'hf32129;
                8'd191: logo_palette_rom = 24'hf1252d;
                8'd192: logo_palette_rom = 24'hf3272e;
                8'd193: logo_palette_rom = 24'hf32a31;
                8'd194: logo_palette_rom = 24'hf42d34;
                8'd195: logo_palette_rom = 24'hf43138;
                8'd196: logo_palette_rom = 24'hf4373e;
                8'd197: logo_palette_rom = 24'hf53c43;
                8'd198: logo_palette_rom = 24'hf54147;
                8'd199: logo_palette_rom = 24'hf6454b;
                8'd200: logo_palette_rom = 24'hf54c52;
                8'd201: logo_palette_rom = 24'hf54e55;
                8'd202: logo_palette_rom = 24'hf94c52;
                8'd203: logo_palette_rom = 24'hf7545a;
                8'd204: logo_palette_rom = 24'hf5595f;
                8'd205: logo_palette_rom = 24'hf75d62;
                8'd206: logo_palette_rom = 24'hf96065;
                8'd207: logo_palette_rom = 24'hf86166;
                8'd208: logo_palette_rom = 24'hf5646a;
                8'd209: logo_palette_rom = 24'hf5666a;
                8'd210: logo_palette_rom = 24'hf6656a;
                8'd211: logo_palette_rom = 24'hf7666b;
                8'd212: logo_palette_rom = 24'hf6686c;
                8'd213: logo_palette_rom = 24'hf9676c;
                8'd214: logo_palette_rom = 24'hf96b70;
                8'd215: logo_palette_rom = 24'hfa6e73;
                8'd216: logo_palette_rom = 24'hf57276;
                8'd217: logo_palette_rom = 24'hf47579;
                8'd218: logo_palette_rom = 24'hf87377;
                8'd219: logo_palette_rom = 24'hf7767a;
                8'd220: logo_palette_rom = 24'hfa797d;
                8'd221: logo_palette_rom = 24'hf87b7f;
                8'd222: logo_palette_rom = 24'hfb7a7f;
                8'd223: logo_palette_rom = 24'hf87c80;
                8'd224: logo_palette_rom = 24'hf77e81;
                8'd225: logo_palette_rom = 24'hf77f82;
                8'd226: logo_palette_rom = 24'hf98185;
                8'd227: logo_palette_rom = 24'hf58386;
                8'd228: logo_palette_rom = 24'hfa8084;
                8'd229: logo_palette_rom = 24'hfb8185;
                8'd230: logo_palette_rom = 24'hf78588;
                8'd231: logo_palette_rom = 24'hf9878a;
                8'd232: logo_palette_rom = 24'hf78a8c;
                8'd233: logo_palette_rom = 24'hf98b8e;
                8'd234: logo_palette_rom = 24'hfb8c90;
                8'd235: logo_palette_rom = 24'hf98d90;
                8'd236: logo_palette_rom = 24'hf69193;
                8'd237: logo_palette_rom = 24'hf98f92;
                8'd238: logo_palette_rom = 24'hf89698;
                8'd239: logo_palette_rom = 24'hf9989a;
                8'd240: logo_palette_rom = 24'hfb9a9d;
                8'd241: logo_palette_rom = 24'hf99c9f;
                8'd242: logo_palette_rom = 24'hfba1a3;
                8'd243: logo_palette_rom = 24'hfaa8ab;
                8'd244: logo_palette_rom = 24'hfaacae;
                8'd245: logo_palette_rom = 24'hfab0b2;
                8'd246: logo_palette_rom = 24'hfab6b8;
                8'd247: logo_palette_rom = 24'hfabdbf;
                8'd248: logo_palette_rom = 24'hfbc1c2;
                8'd249: logo_palette_rom = 24'hfbc4c5;
                8'd250: logo_palette_rom = 24'hfbcbcc;
                8'd251: logo_palette_rom = 24'hfccfd0;
                8'd252: logo_palette_rom = 24'hfcd3d4;
                8'd253: logo_palette_rom = 24'hfcd7d8;
                8'd254: logo_palette_rom = 24'hfcdbdc;
                8'd255: logo_palette_rom = 24'hfcdfe0;
                default: logo_palette_rom = 24'h000000;
            endcase
        end
    endfunction

    osd_char_lib u_osd_char_lib(
        .I_char     ( S_pf_char     ),
        .I_row      ( S_pf_row      ),
        .O_row_bits ( S_pf_row_bits )
    );

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_x <= 12'd0;
            S_y <= 12'd0;
        end
        else if(I_video_user) begin
            S_x <= 12'd0;
            S_y <= 12'd0;
        end
        else if(I_video_de) begin
            if(I_video_last) begin
                S_x <= 12'd0;
                S_y <= S_y + 12'd1;
            end
            else begin
                S_x <= S_x + 12'd1;
            end
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_frame_cnt <= 32'd0;
            S_cnt_d0 <= 4'd0;
            S_cnt_d1 <= 4'd0;
            S_cnt_d2 <= 4'd0;
            S_cnt_d3 <= 4'd0;
            S_cnt_d4 <= 4'd0;
            S_cnt_d5 <= 4'd0;
        end
        else if(I_video_user) begin
            S_frame_cnt <= S_frame_cnt + 32'd1;
            if(S_cnt_d0 == 4'd9) begin
                S_cnt_d0 <= 4'd0;
                if(S_cnt_d1 == 4'd9) begin
                    S_cnt_d1 <= 4'd0;
                    if(S_cnt_d2 == 4'd9) begin
                        S_cnt_d2 <= 4'd0;
                        if(S_cnt_d3 == 4'd9) begin
                            S_cnt_d3 <= 4'd0;
                            if(S_cnt_d4 == 4'd9) begin
                                S_cnt_d4 <= 4'd0;
                                if(S_cnt_d5 == 4'd9)
                                    S_cnt_d5 <= 4'd0;
                                else
                                    S_cnt_d5 <= S_cnt_d5 + 4'd1;
                            end
                            else
                                S_cnt_d4 <= S_cnt_d4 + 4'd1;
                        end
                        else
                            S_cnt_d3 <= S_cnt_d3 + 4'd1;
                    end
                    else
                        S_cnt_d2 <= S_cnt_d2 + 4'd1;
                end
                else
                    S_cnt_d1 <= S_cnt_d1 + 4'd1;
            end
            else
                S_cnt_d0 <= S_cnt_d0 + 4'd1;
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_x_1d <= 12'd0;
            S_x_2d <= 12'd0;
            S_y_1d <= 12'd0;
            S_y_2d <= 12'd0;
        end
        else begin
            S_x_1d <= S_x;
            S_x_2d <= S_x_1d;
            S_y_1d <= S_y;
            S_y_2d <= S_y_1d;
        end
    end

    // ========================================================================
    // [P1b] Logo row-base tracking + palette lookup (replaces the y*160 multiplier)
    // ------------------------------------------------------------------------
    // Cropped Logo region = 146 x 94, screen origin (LOGO_X+7, LOGO_Y+34)
    //   dy = S_y_1d - (LOGO_Y + LOGO_ROM_Y0)     0..93
    //   dx = S_x_1d - (LOGO_X + LOGO_ROM_X0)     0..145
    //   rom_addr = dy * 146 + dx
    // The row base only changes at the first pixel of each row, so no multiplier
    // is needed. Using the PREVIOUS row's base covers the whole row including its
    // first pixel (see doc/analysis/P1b设计-* section 3.2).
    // Using _1d coordinates: the ROM has 1 cycle of read latency, so computing
    // the address one stage early absorbs it and the Logo stays aligned with
    // S_video_data_2d (no 1-pixel shift to the right).
    // ========================================================================
    wire S_logo_rowb_update =
        (S_y_1d >= (LOGO_Y + LOGO_ROM_Y0)) &&
        (S_y_1d <  (LOGO_Y + LOGO_ROM_Y0 + LOGO_ROM_H)) &&
        (S_x_1d == (LOGO_X + LOGO_ROM_X0));
    wire S_logo_in_v_now =
        (S_y_1d >= (LOGO_Y + LOGO_ROM_Y0)) &&
        (S_y_1d <  (LOGO_Y + LOGO_ROM_Y0 + LOGO_ROM_H));

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_logo_rowb_cur <= 15'd0;
            S_logo_rowb_pre <= 15'd0;
            S_logo_in_v     <= 1'b0;
            S_logo_pixel_r  <= 24'd0;
        end
        else begin
            S_logo_rowb_pre <= S_logo_rowb_cur;
            S_logo_in_v     <= S_logo_in_v_now;
            if(!S_logo_in_v_now)
                S_logo_rowb_cur <= 15'd0;                    // clear on entering/leaving
            else if(S_logo_rowb_update)
                S_logo_rowb_cur <= S_logo_rowb_cur + 15'd146; // advance one row
            // palette lookup (combinational function); index 0 = transparent
            S_logo_pixel_r <= logo_palette_rom(S_logo_idx);
        end
    end

    // ROM address: first pixel of a row uses the previous row's base
    assign S_logo_addr14 = (S_x_1d == (LOGO_X + LOGO_ROM_X0))
                         ? (S_logo_rowb_pre[13:0] + (S_x_1d - (LOGO_X + LOGO_ROM_X0)))
                         : (S_logo_rowb_cur[13:0] + (S_x_1d - (LOGO_X + LOGO_ROM_X0)));

    always @(*) begin
        S_osd_hit   = 1'b0;
        S_osd_color = 24'd0;

        S_char_idx = 4'd0;
        S_char_row = 3'd0;
        S_char_col = 3'd0;
        S_char_bits = 5'd0;
        S_char_on = 1'b0;
        S_logo_blue_on = 1'b0;
        S_logo_red_on = 1'b0;
        S_logo_tmp_y = 12'd0;
        S_logo_red_band = 4'd0;
        S_logo_red_x_start = 12'd0;
        S_logo_red_x_end = 12'd0;
        S_dyn_x = 12'd0;
        S_dyn_y = 12'd0;
        S_dyn_char = 4'd0;
        S_dyn_col = 3'd0;
        S_dyn_row = 3'd0;
        S_dyn_bits = 5'd0;
        S_dyn_on = 1'b0;
        S_dyn_digit_idx = 4'd0;
        S_dyn_digit_x = 12'd0;
        S_dyn_seg = 7'd0;
        S_lbl_row = 3'd0;
        S_lbl_col = 3'd0;
        S_lbl_idx = 2'd0;
        S_lbl_bits = 5'd0;
        S_lbl_local_x = 7'd0;
        S_dyn_dec_digit = 4'd0;
        S_cn_local_x = 5'd0;
        S_cn_local_y = 5'd0;
        S_cn_col = 4'd0;
        S_cn_row = 4'd0;
        S_cn_row_bits = 16'd0;
        S_cn_on = 1'b0;
        S_cn_scale_x = 10'd0;
        S_cn_scale_y = 10'd0;
        S_pf_char = 8'd0;
        S_pf_local_x = 5'd0;
        S_pf_local_y = 5'd0;
        S_pf_col = 4'd0;
        S_pf_row = 4'd0;
        S_pf_on = 1'b0;
        S_pf_scale_x = 10'd0;
        S_pf_scale_y = 10'd0;
        // ---- ★ P3：延迟文本区默认值 ----
        //   本块是 S_lat_* 与 S_pf_char/S_pf_row 的**唯一**驱动块
        //   （另一个 always @(*) 只驱动状态条与模式数字），
        //   故延迟区必须放在**本块**内，否则会报 HDL-8007 多驱动。
        S_lat_hit     = 1'b0;
        S_lat_color   = 24'd0;
        S_lat_local_x = 12'd0;
        S_lat_local_y = 12'd0;
        S_lat_char    = 8'h20;
        S_lat_on      = 1'b0;
        S_lat_d1      = 4'd0;
        S_lat_d2      = 4'd0;
        S_lat_d3      = 4'd0;
        S_lat_v       = 10'd0;
        S_lat_r       = 10'd0;
        S_lat_r2      = 10'd0;

        // ---- ★ P5：目标框 / 目标文字区默认值 ----
        //   同 S_lat_*：本块是它们的**唯一**驱动块（另一个 always @(*) 只驱动
        //   状态条与模式数字），放错块会报 HDL-8007 多驱动。
        S_tgt_hit     = 1'b0;
        S_tgt_color   = 24'd0;
        S_tgt_local_x = 12'd0;
        S_tgt_local_y = 12'd0;
        S_tgt_char    = 8'h20;
        S_tgt_on      = 1'b0;

        // ---- ★ P7：运动计数行默认值 ----
        S_minfo_hit     = 1'b0;
        S_minfo_color   = 24'd0;
        S_minfo_local_x = 12'd0;
        S_minfo_local_y = 12'd0;
        S_minfo_char    = 8'h20;
        S_minfo_on      = 1'b0;

        // ---- ★ 目标坐标行默认值 ----
        S_tpos_hit      = 1'b0;
        S_tpos_color    = 24'd0;
        S_tpos_local_x  = 12'd0;
        S_tpos_local_y  = 12'd0;
        S_tpos_char     = 8'h20;
        S_tpos_on       = 1'b0;

        // ---- ★ P6：AE 状态文字区默认值 ----
        S_ae_hit      = 1'b0;
        S_ae_color    = 24'd0;
        S_ae_local_x  = 12'd0;
        S_ae_local_y  = 12'd0;
        S_ae_char     = 8'h20;
        S_ae_on       = 1'b0;

        if(S_video_de_2d) begin
            // [P1b] Logo: ROM read is synchronous, so S_logo_pixel_r is valid here.
            //        palette index 0 means transparent.
            if((S_x_2d >= (LOGO_X + LOGO_ROM_X0)) &&
               (S_x_2d <  (LOGO_X + LOGO_ROM_X0 + LOGO_ROM_W)) &&
               (S_y_2d >= (LOGO_Y + LOGO_ROM_Y0)) &&
               (S_y_2d <  (LOGO_Y + LOGO_ROM_Y0 + LOGO_ROM_H))) begin
                if(S_logo_idx != 8'd0) begin
                    S_osd_hit   = 1'b1;
                    S_osd_color = S_logo_pixel_r;
                end
            end

            if((!S_osd_hit) &&
               (S_x_2d >= DYN_OSD_X) && (S_x_2d < (DYN_OSD_X + DYN_OSD_W)) &&
               (S_y_2d >= DYN_OSD_Y) && (S_y_2d < (DYN_OSD_Y + DYN_OSD_H))) begin
                S_dyn_x = S_x_2d - DYN_OSD_X;
                S_dyn_y = S_y_2d - DYN_OSD_Y;

                // Unified prefix render using one character library.
                // an:[0..23], lu:[24..47], C:[52..67], N:[68..83], T:[84..99], :[100..107]
                if((S_dyn_x < 12'd108) && (S_dyn_y < 12'd24)) begin
                    if((S_dyn_x < 12'd24) || ((S_dyn_x >= 12'd24) && (S_dyn_x < 12'd48))) begin
                        if(S_dyn_y >= CN_Y_OFFSET)
                            S_pf_local_y = S_dyn_y - CN_Y_OFFSET;
                        else
                            S_pf_local_y = 5'd31;

                        if(S_dyn_x < 12'd24) begin
                            S_pf_char = CHAR_AN;
                            S_pf_local_x = S_dyn_x;
                        end
                        else begin
                            S_pf_char = CHAR_LU;
                            S_pf_local_x = S_dyn_x - 12'd24;
                        end

                        if((S_pf_local_x < 5'd24) && (S_pf_local_y < 5'd24)) begin
                            S_pf_scale_x = S_pf_local_x * 10'd16;
                            S_pf_scale_y = S_pf_local_y * 10'd16;
                            S_pf_col = S_pf_scale_x / 10'd24;
                            S_pf_row = S_pf_scale_y / 10'd24;
                            case(S_pf_col)
                                4'd0:  S_pf_on = S_pf_row_bits[15];
                                4'd1:  S_pf_on = S_pf_row_bits[14];
                                4'd2:  S_pf_on = S_pf_row_bits[13];
                                4'd3:  S_pf_on = S_pf_row_bits[12];
                                4'd4:  S_pf_on = S_pf_row_bits[11];
                                4'd5:  S_pf_on = S_pf_row_bits[10];
                                4'd6:  S_pf_on = S_pf_row_bits[9];
                                4'd7:  S_pf_on = S_pf_row_bits[8];
                                4'd8:  S_pf_on = S_pf_row_bits[7];
                                4'd9:  S_pf_on = S_pf_row_bits[6];
                                4'd10: S_pf_on = S_pf_row_bits[5];
                                4'd11: S_pf_on = S_pf_row_bits[4];
                                4'd12: S_pf_on = S_pf_row_bits[3];
                                4'd13: S_pf_on = S_pf_row_bits[2];
                                4'd14: S_pf_on = S_pf_row_bits[1];
                                4'd15: S_pf_on = S_pf_row_bits[0];
                                default: S_pf_on = 1'b0;
                            endcase
                        end
                    end
                    else if((S_dyn_x >= 12'd52) && (S_dyn_x < 12'd100) && (S_dyn_y >= 12'd4) && (S_dyn_y < 12'd20)) begin
                        if(S_dyn_x < 12'd68) begin
                            S_pf_char = CHAR_C;
                            S_pf_local_x = S_dyn_x - 12'd52;
                        end
                        else if(S_dyn_x < 12'd84) begin
                            S_pf_char = CHAR_N;
                            S_pf_local_x = S_dyn_x - 12'd68;
                        end
                        else begin
                            S_pf_char = CHAR_T;
                            S_pf_local_x = S_dyn_x - 12'd84;
                        end
                        S_pf_local_y = S_dyn_y - 12'd4;
                        S_pf_col = S_pf_local_x[3:0];
                        S_pf_row = S_pf_local_y[3:0];
                        case(S_pf_col)
                            4'd0:  S_pf_on = S_pf_row_bits[15];
                            4'd1:  S_pf_on = S_pf_row_bits[14];
                            4'd2:  S_pf_on = S_pf_row_bits[13];
                            4'd3:  S_pf_on = S_pf_row_bits[12];
                            4'd4:  S_pf_on = S_pf_row_bits[11];
                            4'd5:  S_pf_on = S_pf_row_bits[10];
                            4'd6:  S_pf_on = S_pf_row_bits[9];
                            4'd7:  S_pf_on = S_pf_row_bits[8];
                            4'd8:  S_pf_on = S_pf_row_bits[7];
                            4'd9:  S_pf_on = S_pf_row_bits[6];
                            4'd10: S_pf_on = S_pf_row_bits[5];
                            4'd11: S_pf_on = S_pf_row_bits[4];
                            4'd12: S_pf_on = S_pf_row_bits[3];
                            4'd13: S_pf_on = S_pf_row_bits[2];
                            4'd14: S_pf_on = S_pf_row_bits[1];
                            4'd15: S_pf_on = S_pf_row_bits[0];
                            default: S_pf_on = 1'b0;
                        endcase
                    end
                    else if((S_dyn_x >= 12'd100) && (S_dyn_x < 12'd108) && (S_dyn_y >= 12'd4) && (S_dyn_y < 12'd20)) begin
                        S_pf_char = CHAR_COLON;
                        S_pf_local_x = S_dyn_x - 12'd100;
                        S_pf_local_y = S_dyn_y - 12'd4;
                        S_pf_scale_x = S_pf_local_x * 10'd16;
                        S_pf_col = S_pf_scale_x / 10'd8;
                        S_pf_row = S_pf_local_y[3:0];
                        case(S_pf_col)
                            4'd0:  S_pf_on = S_pf_row_bits[15];
                            4'd1:  S_pf_on = S_pf_row_bits[14];
                            4'd2:  S_pf_on = S_pf_row_bits[13];
                            4'd3:  S_pf_on = S_pf_row_bits[12];
                            4'd4:  S_pf_on = S_pf_row_bits[11];
                            4'd5:  S_pf_on = S_pf_row_bits[10];
                            4'd6:  S_pf_on = S_pf_row_bits[9];
                            4'd7:  S_pf_on = S_pf_row_bits[8];
                            4'd8:  S_pf_on = S_pf_row_bits[7];
                            4'd9:  S_pf_on = S_pf_row_bits[6];
                            4'd10: S_pf_on = S_pf_row_bits[5];
                            4'd11: S_pf_on = S_pf_row_bits[4];
                            4'd12: S_pf_on = S_pf_row_bits[3];
                            4'd13: S_pf_on = S_pf_row_bits[2];
                            4'd14: S_pf_on = S_pf_row_bits[1];
                            4'd15: S_pf_on = S_pf_row_bits[0];
                            default: S_pf_on = 1'b0;
                        endcase
                    end

                    if(S_pf_on)
                        S_dyn_on = 1'b1;
                end

                // Decimal 6 digits starts at x=110. Each digit is 15x24.
                if((S_dyn_x >= 12'd110) && (S_dyn_x < 12'd200)) begin
                    if(S_dyn_x < 12'd125) begin
                        S_dyn_digit_idx = 4'd0;
                        S_dyn_digit_x = S_dyn_x - 12'd110;
                        S_dyn_dec_digit = S_cnt_d5;
                    end
                    else if(S_dyn_x < 12'd140) begin
                        S_dyn_digit_idx = 4'd1;
                        S_dyn_digit_x = S_dyn_x - 12'd125;
                        S_dyn_dec_digit = S_cnt_d4;
                    end
                    else if(S_dyn_x < 12'd155) begin
                        S_dyn_digit_idx = 4'd2;
                        S_dyn_digit_x = S_dyn_x - 12'd140;
                        S_dyn_dec_digit = S_cnt_d3;
                    end
                    else if(S_dyn_x < 12'd170) begin
                        S_dyn_digit_idx = 4'd3;
                        S_dyn_digit_x = S_dyn_x - 12'd155;
                        S_dyn_dec_digit = S_cnt_d2;
                    end
                    else if(S_dyn_x < 12'd185) begin
                        S_dyn_digit_idx = 4'd4;
                        S_dyn_digit_x = S_dyn_x - 12'd170;
                        S_dyn_dec_digit = S_cnt_d1;
                    end
                    else begin
                        S_dyn_digit_idx = 4'd5;
                        S_dyn_digit_x = S_dyn_x - 12'd185;
                        S_dyn_dec_digit = S_cnt_d0;
                    end

                    // Render decimal digits through unified 16x16 character library.
                    // Keep enlarged 15x24 box for readability.
                    if((S_dyn_digit_x < 12'd15) && (S_dyn_y < 12'd24)) begin
                        S_pf_char = CHAR_0 + {4'd0, S_dyn_dec_digit};
                        S_pf_local_x = S_dyn_digit_x[4:0];
                        S_pf_local_y = S_dyn_y[4:0];
                        S_pf_scale_x = S_pf_local_x * 10'd16;
                        S_pf_scale_y = S_pf_local_y * 10'd16;
                        S_pf_col = S_pf_scale_x / 10'd15;
                        S_pf_row = S_pf_scale_y / 10'd24;
                        case(S_pf_col)
                            4'd0:  S_pf_on = S_pf_row_bits[15];
                            4'd1:  S_pf_on = S_pf_row_bits[14];
                            4'd2:  S_pf_on = S_pf_row_bits[13];
                            4'd3:  S_pf_on = S_pf_row_bits[12];
                            4'd4:  S_pf_on = S_pf_row_bits[11];
                            4'd5:  S_pf_on = S_pf_row_bits[10];
                            4'd6:  S_pf_on = S_pf_row_bits[9];
                            4'd7:  S_pf_on = S_pf_row_bits[8];
                            4'd8:  S_pf_on = S_pf_row_bits[7];
                            4'd9:  S_pf_on = S_pf_row_bits[6];
                            4'd10: S_pf_on = S_pf_row_bits[5];
                            4'd11: S_pf_on = S_pf_row_bits[4];
                            4'd12: S_pf_on = S_pf_row_bits[3];
                            4'd13: S_pf_on = S_pf_row_bits[2];
                            4'd14: S_pf_on = S_pf_row_bits[1];
                            4'd15: S_pf_on = S_pf_row_bits[0];
                            default: S_pf_on = 1'b0;
                        endcase
                        if(S_pf_on)
                            S_dyn_on = 1'b1;
                    end
                end

                if(S_dyn_on) begin
                    S_osd_hit = 1'b1;
                    S_osd_color = COLOR_DYN_TEXT;
                end
            end

            // ================================================================
            // ★ P3 新增：延迟文本 "LATENCY: ### ms"（高阶要求③ 处理延迟可视化）
            // ----------------------------------------------------------------
            //  必须放在**本块**内：全模块只有一个 osd_char_lib 例化，
            //  其输入 S_pf_char / S_pf_row 只允许由本 always 块驱动。
            //
            //  字符槽 16x16，与 8x16 点阵 **1:1**：
            //      S_pf_row = local_y[3:0]，列 = local_x[3:0]
            //  ⇒ **零乘法、零除法**（既有区域用 `*16 / 24`，会拉长组合路径，
            //     本区刻意避开，以免进一步恶化 HDMI 域时序）
            //
            //  只在**笔画像素**处命中（S_lat_hit 由 S_lat_on 决定），
            //  其余像素透出视频，不会出现"黑底方块"。
            // ================================================================
            if ((S_x_2d >= LAT_X) && (S_x_2d < (LAT_X + LAT_W)) &&
                (S_y_2d >= LAT_Y) && (S_y_2d < (LAT_Y + LAT_H))) begin

                S_lat_local_x = S_x_2d - LAT_X;
                S_lat_local_y = S_y_2d - LAT_Y;

                // ---- 延迟值 → 3 位十进制 ----
                //  ⚠ 时序教训（实测）：这里若直接做 `v/100` 与 `v%100/10` 的
                //  **链式除法**，再串上字符码/字模查表，会把 HDMI_PIXEL_CLK 域的
                //  关键路径拉到 17 级逻辑（SWNS 只剩 0.344 ns，Fmax 76.99 MHz）。
                //  故：除法结果先寄存（见 3.2 节流水寄存器），下一拍才用于索引字模。
                //  全程无 `%`，只用一次 `/100` + 比较链 + 移位加法。
                if (!S_lat_valid_r) begin     // 用寄存后的有效位，与 d1_r/d2_r/d3_r 对齐
                    S_lat_d1 = 4'd10;      // 4'd10 => 映射为 '-'
                    S_lat_d2 = 4'd10;
                    S_lat_d3 = 4'd10;
                end else begin
                    S_lat_v  = (I_lat_ms > 32'd999) ? 10'd999 : I_lat_ms[9:0];
                    S_lat_d1 = S_lat_v / 10'd100;              // 百位 0..9（唯一一次除法）
                    S_lat_r  = S_lat_v - (S_lat_d1 * 10'd100); // 余数 0..99（*100 为移位加法）
                    // 十位：比较链（只比较常数，无除法）
                    if      (S_lat_r >= 10'd90) S_lat_d2 = 4'd9;
                    else if (S_lat_r >= 10'd80) S_lat_d2 = 4'd8;
                    else if (S_lat_r >= 10'd70) S_lat_d2 = 4'd7;
                    else if (S_lat_r >= 10'd60) S_lat_d2 = 4'd6;
                    else if (S_lat_r >= 10'd50) S_lat_d2 = 4'd5;
                    else if (S_lat_r >= 10'd40) S_lat_d2 = 4'd4;
                    else if (S_lat_r >= 10'd30) S_lat_d2 = 4'd3;
                    else if (S_lat_r >= 10'd20) S_lat_d2 = 4'd2;
                    else if (S_lat_r >= 10'd10) S_lat_d2 = 4'd1;
                    else                        S_lat_d2 = 4'd0;
                    // 个位：余数减十位*10（*10 为移位加法）
                    S_lat_r2 = S_lat_r - ({6'd0, S_lat_d2} * 10'd10);
                    if      (S_lat_r2 >= 10'd9) S_lat_d3 = 4'd9;
                    else if (S_lat_r2 >= 10'd8) S_lat_d3 = 4'd8;
                    else if (S_lat_r2 >= 10'd7) S_lat_d3 = 4'd7;
                    else if (S_lat_r2 >= 10'd6) S_lat_d3 = 4'd6;
                    else if (S_lat_r2 >= 10'd5) S_lat_d3 = 4'd5;
                    else if (S_lat_r2 >= 10'd4) S_lat_d3 = 4'd4;
                    else if (S_lat_r2 >= 10'd3) S_lat_d3 = 4'd3;
                    else if (S_lat_r2 >= 10'd2) S_lat_d3 = 4'd2;
                    else if (S_lat_r2 >= 10'd1) S_lat_d3 = 4'd1;
                    else                        S_lat_d3 = 4'd0;
                end

                // ---- 槽位 → 字符码（字符串 "LATENCY: ### ms"）----
                S_lat_char = 8'h20;
                case (S_lat_local_x >> 4)                      // 槽号 = local_x/16
                    4'd0: S_lat_char = 8'h4C;                  // 'L'
                    4'd1: S_lat_char = 8'h41;                  // 'A'
                    4'd2: S_lat_char = 8'h54;                  // 'T'
                    4'd3: S_lat_char = 8'h45;                  // 'E'
                    4'd4: S_lat_char = 8'h4E;                  // 'N'
                    4'd5: S_lat_char = 8'h43;                  // 'C'
                    4'd6: S_lat_char = 8'h59;                  // 'Y'
                    4'd7: S_lat_char = 8'h3A;                  // ':'
                    4'd8: S_lat_char = (S_lat_d1_r == 4'd10) ? 8'h2D : (8'h30 + {4'd0, S_lat_d1_r});
                    4'd9: S_lat_char = (S_lat_d2_r == 4'd10) ? 8'h2D : (8'h30 + {4'd0, S_lat_d2_r});
                    4'd10:S_lat_char = (S_lat_d3_r == 4'd10) ? 8'h2D : (8'h30 + {4'd0, S_lat_d3_r});
                    4'd11:S_lat_char = 8'h20;                  // 空格
                    4'd12:S_lat_char = 8'h6D;                  // 'm'
                    4'd13:S_lat_char = 8'h73;                  // 's'
                    default: S_lat_char = 8'h20;
                endcase

                // ---- 驱动共用的字模查表输入 ----
                S_pf_char = S_lat_char;
                S_pf_row  = S_lat_local_y[3:0];

                // ---- 从 16 bit 行位图取该列（MSB 是最左列）----
                case (S_lat_local_x[3:0])
                    4'd0:  S_lat_on = S_pf_row_bits[15];
                    4'd1:  S_lat_on = S_pf_row_bits[14];
                    4'd2:  S_lat_on = S_pf_row_bits[13];
                    4'd3:  S_lat_on = S_pf_row_bits[12];
                    4'd4:  S_lat_on = S_pf_row_bits[11];
                    4'd5:  S_lat_on = S_pf_row_bits[10];
                    4'd6:  S_lat_on = S_pf_row_bits[9];
                    4'd7:  S_lat_on = S_pf_row_bits[8];
                    4'd8:  S_lat_on = S_pf_row_bits[7];
                    4'd9:  S_lat_on = S_pf_row_bits[6];
                    4'd10: S_lat_on = S_pf_row_bits[5];
                    4'd11: S_lat_on = S_pf_row_bits[4];
                    4'd12: S_lat_on = S_pf_row_bits[3];
                    4'd13: S_lat_on = S_pf_row_bits[2];
                    4'd14: S_lat_on = S_pf_row_bits[1];
                    default:S_lat_on = S_pf_row_bits[0];
                endcase

                if (S_lat_on) begin
                    S_lat_hit   = 1'b1;        // 仅笔画像素命中
                    S_lat_color = COLOR_LAT;
                end
            end

            // ================================================================
            // ★ P5 新增：目标检测文字 "BLK 0312,0208"（13 槽 x 16 = 208x16）
            // ----------------------------------------------------------------
            //  必须放在**本块**内（与延迟文本同理：全模块只有一个 osd_char_lib
            //  例化，`S_pf_char`/`S_pf_row` 只允许由本块驱动，否则 HDL-8007 多驱动）。
            //  十进制位已由 **ISP 域**算好跨过来（I_tgt_x_d*/I_tgt_y_d*），
            //  本域只做"槽位→字符码"查表 ⇒ 不在像素率路径上引入除法链。
            //  区域 (256,80) 与既有 5 个区域均不重叠（见文件头 TGT_* 注释）。
            //  形状字段占 4 槽：NONE / BAR / BLK（圆形与方形本版都归 BLK，见
            //  target_detect_96.v 的"已知边界"）。
            // ================================================================
            if ((S_x_2d >= TGT_X) && (S_x_2d < (TGT_X + TGT_W)) &&
                (S_y_2d >= TGT_Y) && (S_y_2d < (TGT_Y + TGT_H))) begin

                S_tgt_local_x = S_x_2d - TGT_X;
                S_tgt_local_y = S_y_2d - TGT_Y;

                // ---- 槽位 → 字符码 ----
                //  ★★ 临时诊断版：显示十六进制内部量（十六进制只是位切片，
                //     **零额外逻辑**、不需要比较链 ⇒ 不会进一步压 HDMI 域时序）。
                //     格式： `Bxx Wxxxxx Cxx/xx`  共 16 槽
                //        Bxx    : 本帧拍数 ÷1024（流正常 = E1 = 225）
                //        Wxxxxx : 本帧暖色像素数（=0 ⇒ 颜色判据从不成立）
                //        Cxx/xx : 帧中心探测像素的 Cb/Cr（用来按实际光照定阈值）
                //     定位完把本段整块换回原来的 `形状 + 坐标` 版本。
                S_tgt_char = 8'h20;
                case (S_tgt_local_x >> 4)                       // 槽号 = local_x/16
                    4'd0 : S_tgt_char = 8'h42;                                   // 'B'
                    4'd1 : S_tgt_char = hexdig(I_tgt_dbg_beat[7:4]);
                    4'd2 : S_tgt_char = hexdig(I_tgt_dbg_beat[3:0]);
                    4'd3 : S_tgt_char = 8'h57;                                   // 'W'
                    4'd4 : S_tgt_char = hexdig(I_tgt_dbg_warm[19:16]);
                    4'd5 : S_tgt_char = hexdig(I_tgt_dbg_warm[15:12]);
                    4'd6 : S_tgt_char = hexdig(I_tgt_dbg_warm[11:8]);
                    4'd7 : S_tgt_char = hexdig(I_tgt_dbg_warm[7:4]);
                    4'd8 : S_tgt_char = hexdig(I_tgt_dbg_warm[3:0]);
                    4'd9 : S_tgt_char = 8'h43;                                   // 'C'
                    4'd10: S_tgt_char = hexdig(I_tgt_dbg_cb[7:4]);
                    4'd11: S_tgt_char = hexdig(I_tgt_dbg_cb[3:0]);
                    4'd12: S_tgt_char = 8'h2F;                                   // '/'
                    4'd13: S_tgt_char = hexdig(I_tgt_dbg_cr[7:4]);
                    4'd14: S_tgt_char = hexdig(I_tgt_dbg_cr[3:0]);
                    default: S_tgt_char = 8'h20;
                endcase

                // ---- 驱动共用的字模查表输入 ----
                S_pf_char = S_tgt_char;
                S_pf_row  = S_tgt_local_y[3:0];

                // ---- 16 bit 行位图取该列（MSB 最左）----
                case (S_tgt_local_x[3:0])
                    4'd0:  S_tgt_on = S_pf_row_bits[15];
                    4'd1:  S_tgt_on = S_pf_row_bits[14];
                    4'd2:  S_tgt_on = S_pf_row_bits[13];
                    4'd3:  S_tgt_on = S_pf_row_bits[12];
                    4'd4:  S_tgt_on = S_pf_row_bits[11];
                    4'd5:  S_tgt_on = S_pf_row_bits[10];
                    4'd6:  S_tgt_on = S_pf_row_bits[9];
                    4'd7:  S_tgt_on = S_pf_row_bits[8];
                    4'd8:  S_tgt_on = S_pf_row_bits[7];
                    4'd9:  S_tgt_on = S_pf_row_bits[6];
                    4'd10: S_tgt_on = S_pf_row_bits[5];
                    4'd11: S_tgt_on = S_pf_row_bits[4];
                    4'd12: S_tgt_on = S_pf_row_bits[3];
                    4'd13: S_tgt_on = S_pf_row_bits[2];
                    4'd14: S_tgt_on = S_pf_row_bits[1];
                    default:S_tgt_on = S_pf_row_bits[0];
                endcase

                if (S_tgt_on) begin
                    S_tgt_hit   = 1'b1;
                    S_tgt_color = COLOR_TGT;
                end
            end

            // ================================================================
            // ★ P7 新增：运动计数行  `M4FF,2D0 N04D2`
            // ----------------------------------------------------------------
            //  格式（16 槽，只用到 14）：M xmin(3hex) ',' ymin(3hex) ' ' N/G blkcnt(4hex)
            //    · 第 11 槽是 **N/G**：`G` = 本帧被判为全局光照突变（AE 动了一下），
            //      此时 O_valid=0、不画框 —— 这一位就是"为什么没框"的直接答案；
            //    · 全部十六进制 ⇒ 纯位切片、零比较链（与 P5 诊断行同理由）。
            // ================================================================
            if ((S_x_2d >= MOTINFO_X) && (S_x_2d < (MOTINFO_X + MOTINFO_W)) &&
                (S_y_2d >= MOTINFO_Y) && (S_y_2d < (MOTINFO_Y + MOTINFO_H))) begin

                S_minfo_local_x = S_x_2d - MOTINFO_X;
                S_minfo_local_y = S_y_2d - MOTINFO_Y;

                S_minfo_char = 8'h20;
                case (S_minfo_local_x >> 4)                  // 槽号 = local_x/16
                    4'd0 : S_minfo_char = 8'h4D;                              // 'M'
                    4'd2 : S_minfo_char = hexdig(I_mot_x_min[10:8]);
                    4'd3 : S_minfo_char = hexdig(I_mot_x_min[7:4]);
                    4'd4 : S_minfo_char = hexdig(I_mot_x_min[3:0]);
                    4'd5 : S_minfo_char = 8'h2C;                              // ','
                    4'd6 : S_minfo_char = hexdig(I_mot_y_min[9:8]);
                    4'd7 : S_minfo_char = hexdig(I_mot_y_min[7:4]);
                    4'd8 : S_minfo_char = hexdig(I_mot_y_min[3:0]);
                    // 第 10 槽：N = 正常运行 / G = 本帧全局光照突变
                    4'd10: S_minfo_char = I_mot_global ? 8'h47 : 8'h4E;
                    4'd12: S_minfo_char = hexdig(I_mot_blkcnt[13:12]);
                    4'd13: S_minfo_char = hexdig(I_mot_blkcnt[11:8]);
                    4'd14: S_minfo_char = hexdig(I_mot_blkcnt[7:4]);
                    4'd15: S_minfo_char = hexdig(I_mot_blkcnt[3:0]);
                    default: S_minfo_char = 8'h20;
                endcase

                S_pf_char = S_minfo_char;
                S_pf_row  = S_minfo_local_y[3:0];

                case (S_minfo_local_x[3:0])
                    4'd0:  S_minfo_on = S_pf_row_bits[15];
                    4'd1:  S_minfo_on = S_pf_row_bits[14];
                    4'd2:  S_minfo_on = S_pf_row_bits[13];
                    4'd3:  S_minfo_on = S_pf_row_bits[12];
                    4'd4:  S_minfo_on = S_pf_row_bits[11];
                    4'd5:  S_minfo_on = S_pf_row_bits[10];
                    4'd6:  S_minfo_on = S_pf_row_bits[9];
                    4'd7:  S_minfo_on = S_pf_row_bits[8];
                    4'd8:  S_minfo_on = S_pf_row_bits[7];
                    4'd9:  S_minfo_on = S_pf_row_bits[6];
                    4'd10: S_minfo_on = S_pf_row_bits[5];
                    4'd11: S_minfo_on = S_pf_row_bits[4];
                    4'd12: S_minfo_on = S_pf_row_bits[3];
                    4'd13: S_minfo_on = S_pf_row_bits[2];
                    4'd14: S_minfo_on = S_pf_row_bits[1];
                    default:S_minfo_on = S_pf_row_bits[0];
                endcase

                if (S_minfo_on) begin
                    S_minfo_hit   = 1'b1;
                    S_minfo_color = COLOR_MOT;
                end
            end

            // ================================================================
            // ★ P6 新增：AE 闭环状态行  `A 07C6 G 59 L 6E`（16 槽 x 16 = 256x16）
            // ----------------------------------------------------------------
            //  必须放在**本块**内（与延迟/目标文本同理：全模块只有一个
            //  osd_char_lib 例化，`S_pf_char`/`S_pf_row` 只允许由本块驱动）。
            //
            //  为什么显示这四个量（而不是显示"AE 正在工作"这种自夸）：
            //    · A/M —— 证明"当前确实是自动"，也是短按 KEY2 手势的可见反馈；
            //    · 曝光值 —— 闭环的主要手段，饱和时一眼看出（1990 = 0x7C6 顶格）；
            //    · 增益值 —— **本次唯一还有余量的手段**（80 → 89），
            //                它是否往上涨，就是"闭环真的在动"的直接证据；
            //    · 平均亮度 —— 被控量本身，收敛与否看它是否稳定在附近。
            //  上板实测默认画面偏暗（详见 ae_ctrl.v 的"硬件天花板"），
            //  所以这一行同时是**问题证据**：能看出"到底是谁到顶了"。
            //
            //  ★ 全部用十六进制：纯位切片 ⇒ 零比较链 ⇒ 不压 HDMI 域时序。
            // ================================================================
            if ((S_x_2d >= AEINFO_X) && (S_x_2d < (AEINFO_X + AEINFO_W)) &&
                (S_y_2d >= AEINFO_Y) && (S_y_2d < (AEINFO_Y + AEINFO_H))) begin

                S_ae_local_x = S_x_2d - AEINFO_X;
                S_ae_local_y = S_y_2d - AEINFO_Y;

                // ---- 槽位 → 字符码 ----
                S_ae_char = 8'h20;
                case (S_ae_local_x >> 4)                        // 槽号 = local_x/16
                    4'd0 : S_ae_char = I_ae_en ? 8'h41 : 8'h4D;  // 'A' 自动 / 'M' 手动
                    // ★ 槽 1：执行机构饱和指示（2026-09-23 上板照片定位后新增）
                    //   '+' = 有执行机构顶在上限（想变亮但没余量）
                    //   '-' = 有执行机构抵在下限（想变暗但没余量）
                    //   ' ' = 正常，闭环还有余量
                    //   为什么必须显示：那天屏上是 `A 07C6 G 59 L 93` ——
                    //   曝光与增益**都到顶**、平均亮度却远高于目标。只看数值要靠心算，
                    //   有了这一位，一眼就能区分"在正常调节"和"卡在极限"。
                    4'd1 : S_ae_char = I_ae_sat[1] ? 8'h2B :      // '+'
                                       (I_ae_sat[0] ? 8'h2D : 8'h20); // '-' / ' '
                    4'd2 : S_ae_char = hexdig(I_ae_val[15:12]);
                    4'd3 : S_ae_char = hexdig(I_ae_val[11:8]);
                    4'd4 : S_ae_char = hexdig(I_ae_val[7:4]);
                    4'd5 : S_ae_char = hexdig(I_ae_val[3:0]);
                    4'd7 : S_ae_char = 8'h47;                    // 'G'
                    4'd9 : S_ae_char = hexdig(I_ae_ag[7:4]);
                    4'd10: S_ae_char = hexdig(I_ae_ag[3:0]);
                    4'd12: S_ae_char = 8'h4C;                    // 'L'
                    4'd14: S_ae_char = hexdig(I_ae_luma[7:4]);
                    4'd15: S_ae_char = hexdig(I_ae_luma[3:0]);
                    //  ★ 2026-09-27 追加：` K xxxxx` = 本帧过曝像素数（Y>=250 的计数）
                    //    这是判决"高光保护是否在抑制加亮"的唯一直接证据：
                    //    CLIP_PCT 默认 2% => 门限 = 921600*2% = 18432 = 0x04800。
                    //    读数 > 0x04800 说明保护已触发（闭环不许再加亮）；
                    //    接近 0 则说明保护没参与，该去查提交路径而不是改策略。
                    //  ★★ 2026-09-27 真 bug 修复：原来写的是 `4'd16`..`4'd22`。
                    //     **`4'd16` 在 4 位里放不下 ⇒ Verilog 截断成 `4'd0`**：
                    //       · `4'd16`→0、`4'd17`→1 …… `4'd22`→6，与槽 0~6 的项**重名**；
                    //       · case 命中的是**最靠前**那一项 ⇒ 我这 7 个赋值全是**死代码**；
                    //       · 而槽 16~22 本身**没有任何项匹配** ⇒ 落到 default=空格。
                    //     现象：AE 行画到第 16 槽就停住，`K`（常量）和 clip 数据**都不显示**。
                    //     我此前核对过 AEINFO_W(384)、字模 CHAR_K、多驱动、区域判断 ——
                    //     **全对，但都没查到点子上**：病灶在 case 项的**字面量位宽**，
                    //     而我"逐行核对"时看的是**值**（16、17…）不是它的**位宽**。
                    //     ⇒ case 表达式是 8 位（`12b >> 4`），项也用 8 位。
                    8'd16: S_ae_char = 8'h20;                        // 空格
                    8'd17: S_ae_char = 8'h4B;                        // 'K'
                    8'd18: S_ae_char = hexdig(I_ae_clip[19:16]);
                    8'd19: S_ae_char = hexdig(I_ae_clip[15:12]);
                    8'd20: S_ae_char = hexdig(I_ae_clip[11:8]);
                    8'd21: S_ae_char = hexdig(I_ae_clip[7:4]);
                    8'd22: S_ae_char = hexdig(I_ae_clip[3:0]);
                    default: S_ae_char = 8'h20;
                endcase

                // ---- 驱动共用的字模查表输入 ----
                S_pf_char = S_ae_char;
                S_pf_row  = S_ae_local_y[3:0];

                // ---- 16 bit 行位图取该列（MSB 最左）----
                case (S_ae_local_x[3:0])
                    4'd0:  S_ae_on = S_pf_row_bits[15];
                    4'd1:  S_ae_on = S_pf_row_bits[14];
                    4'd2:  S_ae_on = S_pf_row_bits[13];
                    4'd3:  S_ae_on = S_pf_row_bits[12];
                    4'd4:  S_ae_on = S_pf_row_bits[11];
                    4'd5:  S_ae_on = S_pf_row_bits[10];
                    4'd6:  S_ae_on = S_pf_row_bits[9];
                    4'd7:  S_ae_on = S_pf_row_bits[8];
                    4'd8:  S_ae_on = S_pf_row_bits[7];
                    4'd9:  S_ae_on = S_pf_row_bits[6];
                    4'd10: S_ae_on = S_pf_row_bits[5];
                    4'd11: S_ae_on = S_pf_row_bits[4];
                    4'd12: S_ae_on = S_pf_row_bits[3];
                    4'd13: S_ae_on = S_pf_row_bits[2];
                    4'd14: S_ae_on = S_pf_row_bits[1];
                    default:S_ae_on = S_pf_row_bits[0];
                endcase

                if (S_ae_on) begin
                    S_ae_hit   = 1'b1;
                    S_ae_color = COLOR_AE;
                end
            end

            // ================================================================
            // ★ 2026-09-26 新增：目标坐标行 `BLK 0312,0208`
            // ----------------------------------------------------------------
            //  必须放在**本块**内（与延迟/目标/AE 文字同理：全模块只有一个
            //  osd_char_lib 例化，`S_pf_char`/`S_pf_row` 只允许由本块驱动）。
            //  ★ 十进制位由 **ISP 域**算好跨过来（I_tgt_x_d*/I_tgt_y_d*），
            //     本域只做"槽位→字符码"查表 ⇒ **零除法、零比较链**。
            // ================================================================
            if ((S_x_2d >= TGTPOS_X) && (S_x_2d < (TGTPOS_X + TGTPOS_W)) &&
                (S_y_2d >= TGTPOS_Y) && (S_y_2d < (TGTPOS_Y + TGTPOS_H))) begin

                S_tpos_local_x = S_x_2d - TGTPOS_X;
                S_tpos_local_y = S_y_2d - TGTPOS_Y;

                // ---- 槽位 → 字符码 ----
                S_tpos_char = 8'h20;
                case (S_tpos_local_x >> 4)                     // 槽号 = local_x/16
                    // 形状：NONE / BAR / BLK（4 槽，与 I_tgt_shape 对应）
                    4'd0: S_tpos_char = (I_tgt_shape == 2'd0) ? 8'h4E :   // 'N'
                                        ((I_tgt_shape == 2'd1) ? 8'h42 : 8'h42); // 'B'
                    4'd1: S_tpos_char = (I_tgt_shape == 2'd0) ? 8'h4F :   // 'O'
                                        ((I_tgt_shape == 2'd1) ? 8'h41 : 8'h4C); // 'A'/'L'
                    4'd2: S_tpos_char = (I_tgt_shape == 2'd0) ? 8'h4E :   // 'N'
                                        ((I_tgt_shape == 2'd1) ? 8'h52 : 8'h4B); // 'R'/'K'
                    4'd3: S_tpos_char = (I_tgt_shape == 2'd0) ? 8'h45 : 8'h20; // 'E'/空格
                    4'd4: S_tpos_char = 8'h20;
                    // X 四位十进制（千/百/十/个）
                    4'd5: S_tpos_char = 8'h30 + {4'd0, I_tgt_x_d3};
                    4'd6: S_tpos_char = 8'h30 + {4'd0, I_tgt_x_d2};
                    4'd7: S_tpos_char = 8'h30 + {4'd0, I_tgt_x_d1};
                    4'd8: S_tpos_char = 8'h30 + {4'd0, I_tgt_x_d0};
                    4'd9: S_tpos_char = 8'h2C;                     // ','
                    // Y 三位十进制（百/十/个）
                    4'd10: S_tpos_char = 8'h30 + {4'd0, I_tgt_y_d2};
                    4'd11: S_tpos_char = 8'h30 + {4'd0, I_tgt_y_d1};
                    4'd12: S_tpos_char = 8'h30 + {4'd0, I_tgt_y_d0};
                    default: S_tpos_char = 8'h20;
                endcase

                // ---- 驱动共用的字模查表输入 ----
                S_pf_char = S_tpos_char;
                S_pf_row  = S_tpos_local_y[3:0];

                // ---- 16 bit 行位图取该列（MSB 最左）----
                case (S_tpos_local_x[3:0])
                    4'd0:  S_tpos_on = S_pf_row_bits[15];
                    4'd1:  S_tpos_on = S_pf_row_bits[14];
                    4'd2:  S_tpos_on = S_pf_row_bits[13];
                    4'd3:  S_tpos_on = S_pf_row_bits[12];
                    4'd4:  S_tpos_on = S_pf_row_bits[11];
                    4'd5:  S_tpos_on = S_pf_row_bits[10];
                    4'd6:  S_tpos_on = S_pf_row_bits[9];
                    4'd7:  S_tpos_on = S_pf_row_bits[8];
                    4'd8:  S_tpos_on = S_pf_row_bits[7];
                    4'd9:  S_tpos_on = S_pf_row_bits[6];
                    4'd10: S_tpos_on = S_pf_row_bits[5];
                    4'd11: S_tpos_on = S_pf_row_bits[4];
                    4'd12: S_tpos_on = S_pf_row_bits[3];
                    4'd13: S_tpos_on = S_pf_row_bits[2];
                    4'd14: S_tpos_on = S_pf_row_bits[1];
                    default:S_tpos_on = S_pf_row_bits[0];
                endcase

                if (S_tpos_on) begin
                    S_tpos_hit   = 1'b1;
                    S_tpos_color = COLOR_TGTPOS;
                end
            end
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_video_vsync_1d <= 1'b0;
            S_video_vsync_2d <= 1'b0;
            S_video_hsync_1d <= 1'b0;
            S_video_hsync_2d <= 1'b0;
            S_video_de_1d    <= 1'b0;
            S_video_de_2d    <= 1'b0;
            O_hdmi_vsync     <= 1'b0;
            O_hdmi_hsync     <= 1'b0;
            O_hdmi_de        <= 1'b0;
            O_hdmi_data      <= 24'd0;
        end
        else begin
            S_video_vsync_1d <= I_video_vsync;
            S_video_vsync_2d <= S_video_vsync_1d;
            O_hdmi_vsync     <= S_video_vsync_2d;

            S_video_hsync_1d <= I_video_hsync;
            S_video_hsync_2d <= S_video_hsync_1d;
            O_hdmi_hsync     <= S_video_hsync_2d;

            S_video_de_1d    <= I_video_de;
            S_video_de_2d    <= S_video_de_1d;
            O_hdmi_de        <= S_video_de_2d;
            S_video_data_1d  <= I_video_rd_data;
            S_video_data_2d  <= S_video_data_1d;

            if(DEBUG_MODE == 1) begin
                if(S_video_de_2d) begin
                    if(S_x < 12'd128)
                        O_hdmi_data <= 24'hff0000;
                    else if(S_x < 12'd256)
                        O_hdmi_data <= 24'h00ff00;
                    else if(S_x < 12'd384)
                        O_hdmi_data <= 24'h0000ff;
                    else if(S_x < 12'd512)
                        O_hdmi_data <= 24'hffff00;
                    else if(S_x < 12'd640)
                        O_hdmi_data <= 24'h00ffff;
                    else if(S_x < 12'd768)
                        O_hdmi_data <= 24'hff00ff;
                    else if(S_x < 12'd896)
                        O_hdmi_data <= 24'hffffff;
                    else
                        O_hdmi_data <= 24'h202020;
                end
                else begin
                    O_hdmi_data <= 24'd0;
                end
            end
            else if(DEBUG_MODE == 2) begin
                if(S_video_de_2d) begin
                    case (I_debug_status)
                        4'b0000: O_hdmi_data <= 24'h000000;
                        4'b0001: O_hdmi_data <= 24'hff0000;
                        4'b0011: O_hdmi_data <= 24'hffff00;
                        4'b0111: O_hdmi_data <= 24'h00ff00;
                        4'b1111: O_hdmi_data <= I_video_rd_data;
                        default: O_hdmi_data <= 24'h0000ff;
                    endcase
                end
                else begin
                    O_hdmi_data <= 24'd0;
                end
            end
            else if(DEBUG_MODE == 3) begin
                if(S_video_de_2d) begin
                    if(S_x < 12'd256)
                        O_hdmi_data <= I_debug_status[0] ? 24'hff8000 : 24'h201000;
                    else if(S_x < 12'd512)
                        O_hdmi_data <= I_debug_status[1] ? 24'hffff00 : 24'h202000;
                    else if(S_x < 12'd768)
                        O_hdmi_data <= I_debug_status[2] ? 24'hff0000 : 24'h200000;
                    else
                        O_hdmi_data <= I_debug_status[3] ? 24'h00ffff : 24'h002020;
                end
                else begin
                    O_hdmi_data <= 24'd0;
                end
            end
            else begin
                // 优先级：OSD(I_osd_en) > 状态条 > 模式数字 > 目标框 > 延迟文本 > 目标文字
                //         > AE 状态文字 > 视频
                //   目标框放在延迟文本之上（框可能横穿文本区，视觉上框更重要）；
                //   目标文字放在最靠近视频的一层，避免它遮住任何既有元素。
                //   ★ P6 的 AE 状态文字放在**最底层（仅高于视频）**：新加的东西
                //     绝不允许改变任何既有元素的可见性（这是"追加功能不破坏已验收项"的纪律）。
                if(S_osd_hit && I_osd_en)
                    O_hdmi_data <= S_osd_color;
                else if(S_stat_hit)
                    O_hdmi_data <= S_stat_color;
                else if(S_mode_hit)
                    O_hdmi_data <= S_mode_color;
                else if(S_box_hit)
                    O_hdmi_data <= S_box_color;   // ★ P5 目标包围框
                else if(S_mbox_hit)
                    O_hdmi_data <= S_mbox_color;  // ★ P7 运动区域框（在颜色目标框之下）
                else if(S_lat_hit)
                    O_hdmi_data <= S_lat_color;   // ★ P3 延迟文本（无笔画处为黑，正好压暗底）
                else if(S_tgt_hit)
                    O_hdmi_data <= S_tgt_color;   // ★ P5 目标文字
                else if(S_tpos_hit)
                    O_hdmi_data <= S_tpos_color;  // ★ 目标坐标行（进阶② 要求）
                else if(S_minfo_hit)
                    O_hdmi_data <= S_minfo_color; // ★ P7 运动计数行
                else if(S_ae_hit)
                    O_hdmi_data <= S_ae_color;    // ★ P6 AE 状态文字（优先级最低，不遮任何既有元素）
                else
                    O_hdmi_data <= S_video_data_2d;
            end
        end
    end

    // ========================================================================
    // lab_ex4 新增：常显底部状态条 + 右上模式数字（纯组合，无 RAM/ROM）
    // ------------------------------------------------------------------------
    // 二者都只在视频有效区内生效（S_video_de_2d），
    // 因此不使用 S_stat_hit/S_mode_hit 的路径（如 DEBUG_MODE!=0）天然不受影响。
    //
    // 坐标系：S_x_2d / S_y_2d 是**显示坐标**（0..IMG_WIDTH-1 / 0..IMG_HEIGHT-1），
    //         与 S_video_data_2d 同拍，所以叠加与像素严格共位。
    // ========================================================================
    always @(*) begin
        // ---- 默认值 ----
        S_stat_hit   = 1'b0;
        S_stat_color = 24'd0;
        S_stat_idx   = 2'd0;
        S_mode_hit   = 1'b0;
        S_mode_color = 24'd0;
        S_md_local_x = 12'd0;
        S_md_local_y = 12'd0;
        S_md_seg     = 7'd0;
        S_md_a = 1'b0; S_md_b = 1'b0; S_md_c = 1'b0; S_md_d = 1'b0;
        S_md_e = 1'b0; S_md_f = 1'b0; S_md_g = 1'b0;
        S_box_hit   = 1'b0;
        S_box_color = COLOR_BOX;
        // ★ P7：运动框默认值（与目标框同块，都是画在视频上的框）
        S_mbox_hit   = 1'b0;
        S_mbox_color = COLOR_MBOX;

        // ---- ★ P5：目标包围框（4 条 BOX_T 像素宽的边线）----
        //   ⚠ 只在 I_tgt_valid=1 时画 —— **移出画面必须无残留**（本阶段的专门验收项）。
        //   ⚠ 不做减法：比较用"边界 + 线宽"，避免无符号下溢（框内已保证 min≤坐标≤max）。
        // ---- ★ P7：运动区域框（4 条 MOTBOX_T 像素宽边线）----
        //   与目标框同样的纪律：**只在 I_mot_valid=1 时画** ⇒ 运动消失后无残留。
        //   比较用"边界 + 线宽"而不是减法，避免无符号下溢。
        //   ⚠ 块量化 ⇒ 框外扩到 8 像素块边界（最多 ±8 像素），与目标框的 ±80 不同量级。
        if (S_video_de_2d && I_mot_valid &&
            (S_x_2d >= I_mot_x_min) && (S_x_2d <= I_mot_x_max) &&
            (S_y_2d >= I_mot_y_min) && (S_y_2d <= I_mot_y_max)) begin
            if ( (S_y_2d <  (I_mot_y_min + MOTBOX_T)) ||
                 (S_y_2d >= (I_mot_y_max - MOTBOX_T)) ||
                 (S_x_2d <  (I_mot_x_min + MOTBOX_T)) ||
                 (S_x_2d >= (I_mot_x_max - MOTBOX_T)) )
                S_mbox_hit = 1'b1;
        end

        if (S_video_de_2d && I_tgt_valid &&
            (S_x_2d >= I_tgt_x_min) && (S_x_2d <= I_tgt_x_max) &&
            (S_y_2d >= I_tgt_y_min) && (S_y_2d <= I_tgt_y_max)) begin
            if ( (S_y_2d <  (I_tgt_y_min + BOX_T)) ||
                 (S_y_2d >= (I_tgt_y_max - BOX_T)) ||
                 (S_x_2d <  (I_tgt_x_min + BOX_T)) ||
                 (S_x_2d >= (I_tgt_x_max - BOX_T)) )
                S_box_hit = 1'b1;
        end

        // ---- 底部状态条：4 段等分 ----
        if(S_video_de_2d &&
           (S_y_2d >= STATUS_Y) && (S_y_2d < IMG_HEIGHT) &&
           (S_x_2d < IMG_WIDTH)) begin
            S_stat_hit = 1'b1;
            if(S_x_2d < (STATUS_SEGW * 1))
                S_stat_idx = 2'd0;
            else if(S_x_2d < (STATUS_SEGW * 2))
                S_stat_idx = 2'd1;
            else if(S_x_2d < (STATUS_SEGW * 3))
                S_stat_idx = 2'd2;
            else
                S_stat_idx = 2'd3;

            case(S_stat_idx)
                2'd0:    S_stat_color = I_debug_status[0] ? COLOR_STAT_ON_0 : COLOR_STAT_OFF;
                2'd1:    S_stat_color = I_debug_status[1] ? COLOR_STAT_ON_1 : COLOR_STAT_OFF;
                2'd2:    S_stat_color = I_debug_status[2] ? COLOR_STAT_ON_2 : COLOR_STAT_OFF;
                default: S_stat_color = I_debug_status[3] ? COLOR_STAT_ON_3 : COLOR_STAT_OFF;
            endcase
        end

        // ---- 右上模式数字：7 段数码管 ----
        if(S_video_de_2d &&
           (S_x_2d >= MODE_X) && (S_x_2d < (MODE_X + MODE_DW)) &&
           (S_y_2d >= MODE_Y) && (S_y_2d < (MODE_Y + MODE_DH))) begin
            S_mode_hit   = 1'b1;
            S_md_local_x = S_x_2d - MODE_X;
            S_md_local_y = S_y_2d - MODE_Y;
            S_md_seg     = F_mode7seg(I_mode_disp);

            // 各段点亮标志
            S_md_a = S_md_seg[6];   // 上横
            S_md_b = S_md_seg[5];   // 右上竖
            S_md_c = S_md_seg[4];   // 右下竖
            S_md_d = S_md_seg[3];   // 下横
            S_md_e = S_md_seg[2];   // 左下竖
            S_md_f = S_md_seg[1];   // 左上竖
            S_md_g = S_md_seg[0];   // 中横

            // 段命中判决
            if( ((S_md_local_y < MODE_T)                                    && S_md_a) ||
                ((S_md_local_x >= (MODE_DW - MODE_T))                       && S_md_b) ||
                ((S_md_local_x >= (MODE_DW - MODE_T)) &&
                 (S_md_local_y >= (MODE_DH/2))                              && S_md_c) ||
                ((S_md_local_y >= (MODE_DH - MODE_T))                       && S_md_d) ||
                ((S_md_local_x < MODE_T) &&
                 (S_md_local_y >= (MODE_DH/2))                              && S_md_e) ||
                ((S_md_local_x < MODE_T)                                    && S_md_f) ||
                ((S_md_local_y >= ((MODE_DH/2) - (MODE_T/2))) &&
                 (S_md_local_y <  ((MODE_DH/2) + (MODE_T/2)))               && S_md_g) )
                S_mode_color = COLOR_MODE_ON;
            else
                S_mode_color = COLOR_MODE_OFF;
        end
    end

endmodule
