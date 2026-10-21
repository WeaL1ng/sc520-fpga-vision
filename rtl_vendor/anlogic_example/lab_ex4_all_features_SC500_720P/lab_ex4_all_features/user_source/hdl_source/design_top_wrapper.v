

module design_top_wrapper (
    input wire        I_sys_clk,
    input wire        I_rst_n,
      
    output wire       O_cam_scl,
    inout  wire       IO_cam_sda,
    output wire       O_cam_24m,
    output wire       O_cam_rst,
      
    inout wire [1:0]  I_button,

    // ---- ★ 扩展(3)：识别结果 → 外部控制（板载 4 个 LED + 蜂鸣器）----
    //   引脚（已核对 HX1P35B 引脚分配汇总，约束见 user_source/constraints_source/pin.adc）：
    //     O_led[0] = D10 (LED1)   O_led[1] = E10 (LED2)
    //     O_led[2] = C6  (LED3)   O_led[3] = D6  (LED4)
    //     O_buzzer = C12          （板上 SW5 是蜂鸣器使能开关，演示前要拨到 ON）
    output wire [3:0] O_led,
    output wire       O_buzzer,

    output wire       O_screen_pwm,
    output wire       O_tmds_ch0_p,
    output wire       O_tmds_ch1_p,
    output wire       O_tmds_ch2_p,
    output wire       O_tmds_clk_p,

    inout wire        IO_rx_clk_pad_n, 
    inout wire        IO_rx_clk_pad_p, 
    inout wire[3:0]   IO_rx_data_pad_n,
    inout wire[3:0]   IO_rx_data_pad_p,

    output wire[12:0] ddr_addr,
    output wire[ 1:0] ddr_ba,
    output wire[ 0:0] ddr_cke,
    output wire[ 0:0] ddr_odt,
    output wire[ 0:0] ddr_cs_n,
    output wire       ddr_ras_n,
    output wire       ddr_cas_n,
    output wire       ddr_we_n,
    output wire[ 0:0] ddr_ck_p,
    output wire[ 0:0] ddr_ck_n,
    inout wire[1:0]   ddr_dm,
    inout wire[15:0]  ddr_dq,
    inout wire[1:0]   ddr_dqs_p,
    inout wire[1:0]   ddr_dqs_n   
);


    wire        	S_100m_clk;
    wire        	S_24m_clk;
    wire        	S_aux_50m_clk;
	wire        	S_10m_clk;
		
	wire        	S_pll_lock;
    wire        	S_rst_n;
	
	wire [15:0] 	S_ae;
    wire [15:0] 	S_ag;
    wire 			S_cam_cfg_done;
    wire 			S_ae_cfg_done;
    wire 			S_ae_req; 
// ---- lab_ex4 新增：按键模式控制（D1 域）----
// O_mode[1:0]=图像处理模式（0 原图 / 1 灰度 / 2 二值化 / 3 反色）
//   ★ 红线1 改造前：bit0=边缘检测使能、bit1=OSD 使能（两位语义不同）
//   ★ 红线1 改造后：两位**作为一个 2-bit 模式号**整体使用，同时驱动
//     算法通路的 I_img_mode 与 OSD 的模式数字显示，语义一致、不再分叉。
// O_btn_ae=门控后按键(低有效)
wire [2:0]  S_mode_24;        // D1 域模式寄存器（P4 扩为 3 位）
wire [1:0]  S_ae_btn_gated;   // D1 域门控按键（低有效）
wire [2:0]  S_mode_csi;       // D2 域：图像处理模式（2-FF 同步 + 帧首锁存）
wire [2:0]  S_mode_hdmi;      // D4 域：模式数字显示（D1 -> D4 同步）

// ---- ★ P3 新增：端到端延迟可视化（高阶要求③）----
wire [31:0] S_lat_ms;         // 延迟值（毫秒）
wire        S_lat_valid;      // 0 = 尚未测出（OSD 显示 "-"）
wire        S_dis_frame_start;// 显示帧起始脉冲（hdmi_mixer 产生）

	
	wire        	S_csi_rx_clk;  
    wire        	S_hs_rx_valid;  
    wire[15:0]  	S_hs_rx_data;   
	wire[1:0]   	S_lane_error;
	
	wire        	S_csi_frame_start;       
	wire        	S_csi_frame_end;         
	wire        	S_csi_valid;             
	wire[31:0]  	S_csi_data;  
		
	wire        	S_raw10_frame_start; 
	wire        	S_raw10_frame_end;   
	wire        	S_raw10_valid;       
	wire [39:0] 	S_raw10_data;
		
	wire 			S_axis_tlast;  
	wire 			S_axis_tuser;  
	wire [39:0]		S_axis_tdata;  
	wire 			S_axis_tvalid; 
	
	wire [39:0]		S_raw_tdata ;
	wire			S_raw_tlast ;
	wire 			S_raw_tvalid;
	wire 			S_raw_tuser ;
	
	wire			S_ISP_O_tready;
	wire [127:0]	S_ISP_O_tdata ;
	wire 			S_ISP_O_tlast ;
	wire 			S_ISP_O_tuser ;
	wire 			S_ISP_O_tvalid; 
	

    wire        S_ddr_clk;
    wire        S_hdmi_pixel_clk;
    wire        S_hdmi_serial_clk;
    wire        S_hdmi_rst_n;
    wire        S_video_out_rst_n;


    wire        S_vi_128b_frame_start;
    wire        S_vi_128b_valid;      
    wire[127:0] S_vi_128b_data;    
    
    wire        S_video_out_rd_busy;
    wire        S_video_in_wr_busy; 
    wire[1:0]   S_video_out_rp;     

    // ---- ★ P3（2026-09-21 重写）：帧缓冲 BANK 号与两个帧起始脉冲 ----
    //   全部在 S_ddr_clk 域，交给 frame_latency 做"按 BANK 索引"的延迟测量
    wire[1:0]   S_video_in_wp;           // 写 BANK（video_in）
    wire        S_video_in_frame_start;  // 采集帧写入起始（video_in）
    wire        S_video_frame_start;     // 显示帧起始（video_out）

    // ========================================================================
    // ★ P5：颜色目标检测结果（扩展② + 进阶②）
    // ------------------------------------------------------------------------
    //  ① ISP 域侧（isp_top 的输出，S_csi_rx_clk）
    wire [10:0] S_tgt_x_min, S_tgt_x_max;
    wire [9:0]  S_tgt_y_min, S_tgt_y_max;
    wire [7:0]  S_tgt_tiles;
    wire [1:0]  S_tgt_shape;
    wire        S_tgt_valid, S_tgt_frame;
    wire [3:0]  S_tgt_x_d3, S_tgt_x_d2, S_tgt_x_d1, S_tgt_x_d0;
    wire [3:0]  S_tgt_y_d2, S_tgt_y_d1, S_tgt_y_d0;
    //  ★★ 临时诊断（上板定位用；定位完连同 OSD 那一行一起删）
    wire [7:0]  S_tgt_dbg_beat;
    wire [19:0] S_tgt_dbg_warm;
    wire [7:0]  S_tgt_dbg_cb, S_tgt_dbg_cr;
    //  ② 跨到 HDMI 域（见下方"准静态多比特跨域"注释）
    reg         S_tgt_tgl;                       // ISP 域：每帧翻转一次
    reg         S_tgt_t1, S_tgt_t2, S_tgt_t3;    // HDMI 域：2 拍同步 + 1 拍边沿检测
    reg         S_tgt_valid_h;
    reg  [10:0] S_tgt_x_min_h, S_tgt_x_max_h;
    reg  [9:0]  S_tgt_y_min_h, S_tgt_y_max_h;
    reg  [7:0]  S_tgt_tiles_h;
    reg  [1:0]  S_tgt_shape_h;
    reg  [3:0]  S_tgt_x_d3_h, S_tgt_x_d2_h, S_tgt_x_d1_h, S_tgt_x_d0_h;
    reg  [3:0]  S_tgt_y_d2_h, S_tgt_y_d1_h, S_tgt_y_d0_h;
    reg  [7:0]  S_tgt_dbg_beat_h;
    reg  [19:0] S_tgt_dbg_warm_h;
    reg  [7:0]  S_tgt_dbg_cb_h, S_tgt_dbg_cr_h;

    // ========================================================================
    //  ★ P6：AE 闭环（亮度统计跨域 + 控制器 + OSD 显示）
    // ------------------------------------------------------------------------
    //  ① ISP 域（isp_top / luma_stats 的输出，S_csi_rx_clk）
    //     ⚠ 这些量**每帧只变一次**，且 luma_stats 在帧末**先锁存再翻标志**，
    //       所以跨域捕获时数据必定已经静止（详见 ae_ctrl.v 的跨域说明）。
    //  ② 24 MHz 域（ae_ctrl / ae_set / I2C）
    //  ③ HDMI 域（OSD 显示，2-FF 同步 + 边沿捕获，与 P5 的目标文字同一套）
    // ========================================================================
    wire [31:0] S_ae_sum;        // ISP 域：本帧 ΣY
    wire [19:0] S_ae_clip;       // ISP 域：本帧过曝像素数
    wire        S_ae_tog;        // ISP 域：每帧翻转的跨域握手

    wire        S_auto_tog;      // 24M 域：短按 KEY2 的切换脉冲
    reg         S_ae_auto = 1'b1;// 24M 域：1=自动（**上电即自动**，这是 P6 的交付语义）
    wire [15:0] S_ae_auto_ae;    // ae_ctrl 给的自动目标
    wire [15:0] S_ae_auto_ag;
    wire [15:0] S_ae_cur, S_ag_cur;
    wire [1:0]  S_ae_dir;
    wire [15:0] S_ae_upd_cnt;
    wire        S_ae_new_frame;
    wire [1:0]  S_ae_sat;        // 24M 域：执行机构饱和（bit1=顶上 bit0=抵下）

    // ---- ★ P7：运动检测（ISP 域 → HDMI 域，与 P5 目标框同一套跨域论证）----
    wire [10:0] S_mot_x_min, S_mot_x_max;
    wire [9:0]  S_mot_y_min, S_mot_y_max;
    wire [13:0] S_mot_blkcnt;
    wire        S_mot_valid, S_mot_global, S_mot_frame;
    reg         S_mot_tgl;                       // ISP 域：每帧翻转
    reg         S_mot_t1, S_mot_t2, S_mot_t3;    // HDMI 域：2 拍同步 + 1 拍边沿检测
    reg  [10:0] S_mot_x_min_h, S_mot_x_max_h;
    reg  [9:0]  S_mot_y_min_h, S_mot_y_max_h;
    reg  [13:0] S_mot_blkcnt_h;
    reg         S_mot_valid_h, S_mot_global_h;
    wire [7:0]  S_ae_avg_24;     // 24M 域捕获后的平均亮度（送 OSD）
    wire [19:0] S_ae_clip_24;

    // ③ HDMI 显示域：AE 状态（★ 声明必须放在**使用之前**！）
    //   ⚠ 踩坑记录：第一次把这几个 reg 声明写在了下面"P6 跨域"那一节里，
    //     而 `u_hdmi_mixer` 的例化在**更前面** ⇒ TD 报
    //     `HDL-7225 CRITICAL-WARNING: 'S_ae_ae_h' is already implicitly declared`。
    //     Verilog 会先按 1 位隐式线网使用，再看到 16 位 reg 声明 ——
    //     结果 OSD 那一行拿到的可能是**1 位的隐式线**，屏上显示就会是错的。
    //     ModelSim 也会给同样的告警；**编译告警里有"implicitly declared"就必须当错误处理**。
    reg         S_ae_t1, S_ae_t2, S_ae_t3;   // 2 拍同步 + 1 拍边沿检测
    reg  [15:0] S_ae_ae_h, S_ae_ag_h;        // HDMI 域捕获值（送 OSD）
    reg  [7:0]  S_ae_avg_h;
    reg  [19:0] S_ae_clip_h;
    reg         S_ae_auto_h;
    reg  [1:0]  S_ae_sat_h;                  // ★ 饱和指示（送 OSD 首行第 2 槽）
    // 24M 域：AE 相关值一变就翻标志（触发源见下方说明）
    reg         S_ae_osd_tgl;
    reg  [15:0] S_ae_osd_ae_d, S_ae_osd_ag_d;
    reg  [1:0]  S_ae_osd_sat_d;              // 饱和指示的变化检测

    // ★ AG 上限：89 = 厂家增益表原样；111 = 补全表。
    //   ★★ 2026-09-27 **实测依据（不再是推理）**：
    //     · 手动模式把 AG 推到 `G 6F`=111，**画面正常、检测正常**
    //       ⇒ 传感器接受 0x0F30~0x0F3F，补全表**有效**；
    //     · 过曝计数 `K` 实测只有 **46** 和 **0**（门限 = 921600×2% = 18432）
    //       ⇒ **高光保护根本没有参与**，"暗场景拉不亮"纯粹是**增益上限不够**；
    //     · 换算：AG=89→`0x0F29`→**20.5 倍**；AG=111→`0x0F3F`→**31.5 倍（+54%）**
    //       （注：早先文档写的"+97%"是错的，已更正）。
    //   这里用一根常量线同时喂给 ae_ctrl 与 ae_set，保证"自动/手动上限一致"。
    // ★ 2026-10-21 换 SC520CS：增益表 SC520GainTbl 的有效输入是 16..176
    //   （176 -> 0x3e09=0x1f = 32x 模拟增益上限），
    //   曝光以半行为单位、VTS=1000 时合法上限 2*VTS-9 = 1991（厂商 ae_set.v 原注释）。
    localparam [15:0] AE_AG_MAX = 16'd176;
    localparam [15:0] AE_AE_MAX = 16'd1991;

    // ========================================================================
    //  ★ 扩展(3)：识别结果 → 外部控制（声明区，必须早于使用 —— P6 的 HDL-7225 教训）
    // ------------------------------------------------------------------------
    //  ★★ 为什么全部放在 **HDMI 显示域**（而不是 24 MHz 域）：
    //     信号来源是 `S_tgt_valid_h` / `S_tgt_shape_h` / `S_ae_auto_h`，它们**本来
    //     就在 HDMI 域**（P5/P6 的跨域捕获结果，每帧最多变一次）。若为了驱动 LED
    //     把它们再同步回 24 MHz 域，就会**新增一条 HDMI→24M 的跨域路径**——
    //     而 `pll_clk_24m` 与 `HDMI_PIXEL_CLK` 在本工程的 SDC 里被放在**同一个
    //     时钟组**（即被当作同步关系分析），现有 `set_false_path` 只覆盖
    //     24M→HDMI 这一个方向（见 sdc 文件里的详细记录）。
    //     ⇒ **在 HDMI 域就地驱动，跨域数为 0，不需要动任何约束**，
    //       也天然保证"LED 与 OSD 显示的是同一份数据"。
    //     代价：音调分频比要按 75.002 MHz 算（而不是 23.81 MHz），仅此而已。
    // ========================================================================
    reg  [3:0]  S_led_r;                          // LED 输出寄存器（HDMI 域）
    // ---- 蜂鸣器：0.15 s 响 / 0.35 s 停 的 2.7 kHz 提示音（只在检出目标时）----
    //   HDMI_PIXEL_CLK = 75.002 MHz：752? 用 75002000 近似
    localparam integer TONE_HALF = 13889;         // 75.002MHz/(2*13889) ≈ 2.70 kHz
    localparam integer BUZZ_ON   = 11250300;      // ≈0.15 s @75.002MHz
    localparam integer BUZZ_PER  = 37501000;      // ≈0.50 s（一个"哔—停"周期）
    reg  [25:0] S_buzz_c;
    reg  [13:0] S_tone_c;
    reg         S_tone;

    wire        S_ddr_user_wr_en;       
    wire        S_ddr_user_rd_en;       
    wire[24:0]  S_ddr_user_addr;        
    wire[127:0] S_ddr_user_wr_data;     
    wire        S_ddr_user_ready;       
    wire        S_ddr_user_rd_valid;    
    wire[127:0] S_ddr_user_rd_data;     

    wire        S_vi_ddr_wr_en;   
    wire[24:0]  S_vi_ddr_wr_addr; 
    wire[127:0] S_vi_ddr_wr_data;
    wire        S_vi_ddr_wr_ready;

    wire        S_vo_ddr_rd_en;   
    wire[24:0]  S_vo_ddr_rd_addr; 
    wire        S_vo_ddr_rd_ready;
    wire        S_vo_dbg_fifo_rst;
    wire        S_vo_dbg_ddr_rd_valid;
    wire        S_vo_dbg_fifo_rd_en;
    wire        S_vo_dbg_fifo_empty;

    wire        S_init_calib_complete; 
    wire[24:0]  S_mc_app_addr;          
    wire[2:0]   S_mc_app_cmd;           
    wire        S_mc_app_en;            
    wire[127:0] S_mc_app_wdf_data;      
    wire        S_mc_app_wdf_end;       
    wire[15:0]  S_mc_app_wdf_mask;      
    wire        S_mc_app_wdf_wren;      
    wire[127:0] S_mc_app_rd_data;       
    wire        S_mc_app_rd_data_end;   
    wire        S_mc_app_rd_data_valid; 
    wire        S_mc_app_rdy;           
    wire        S_mc_app_wdf_rdy;       
    wire        S_mc_dbg_fifo_afull;
    wire        S_mc_dbg_app_rdy;
    wire        S_mc_dbg_wdf_rdy;
    wire        S_mc_dbg_cmd_pop;

    wire        S_hdmi_vsync;
    wire        S_hdmi_hsync;
    wire        S_hdmi_de;
    wire        S_hdmi_user;
    wire        S_hdmi_last;
    wire        S_video_out_vsync;
    wire        S_hdmi_window_rd_en;
    wire        S_hdmi_out_vsync;
    wire        S_hdmi_out_hsync;
    wire        S_hdmi_out_de;
    wire[23:0]  S_hdmi_out_data;

    wire[23:0]  S_video_rd_data;
    reg         S_dbg_raw_seen;
    reg         S_dbg_isp_seen;
    reg         S_dbg_ddr_wr_seen;
    reg         S_dbg_ddr_rd_seen;
    reg         S_dbg_cam_cfg_seen;
    reg         S_dbg_hs_seen;
    reg         S_dbg_csi_seen;
    reg         S_dbg_raw10_seen;
    reg         S_dbg_isp_fs_seen;
    reg         S_dbg_isp_valid_seen;
    reg         S_dbg_ddr_req_seen;
    reg         S_dbg_ddr_ready_seen;
    reg [1:0]   S_dbg_raw_seen_sync;
    reg [1:0]   S_dbg_isp_seen_sync;
    reg [1:0]   S_dbg_ddr_wr_seen_sync;
    reg [1:0]   S_dbg_ddr_rd_seen_sync;
    reg [1:0]   S_dbg_cam_cfg_seen_sync;
    reg [1:0]   S_dbg_hs_seen_sync;
    reg [1:0]   S_dbg_csi_seen_sync;
    reg [1:0]   S_dbg_raw10_seen_sync;
    reg [1:0]   S_dbg_isp_fs_seen_sync;
    reg [1:0]   S_dbg_isp_valid_seen_sync;
    reg [1:0]   S_dbg_ddr_req_seen_sync;
    reg [1:0]   S_dbg_ddr_ready_seen_sync;
    reg         S_dbg_video_nonzero_seen;
    reg         S_dbg_rd_req_seen;
    reg         S_dbg_rd_valid_seen;
    reg         S_dbg_rd_nonzero_seen;
    reg [1:0]   S_dbg_rd_req_seen_sync;
    reg [1:0]   S_dbg_rd_valid_seen_sync;
    reg [1:0]   S_dbg_rd_nonzero_seen_sync;
    reg         S_dbg_mc_init_seen;
    reg         S_dbg_mc_app_rdy_seen;
    reg         S_dbg_mc_wdf_rdy_seen;
    reg         S_dbg_mc_cmd_pop_seen;
    reg [1:0]   S_dbg_mc_init_seen_sync;
    reg [1:0]   S_dbg_mc_app_rdy_seen_sync;
    reg [1:0]   S_dbg_mc_wdf_rdy_seen_sync;
    reg [1:0]   S_dbg_mc_cmd_pop_seen_sync;
    // 720p input-format diagnostics.  One RAW10 line from the factory
    // 1280-pixel mode contains 1600 bytes, i.e. 400 valid 32-bit CSI words.
    reg         S_dbg_hs_valid_d;
    reg [10:0]  S_dbg_csi_words;
    reg [10:0]  S_dbg_good_lines;
    reg         S_dbg_frame_seen_once;
    reg         S_dbg_frame_repeat_seen;
    reg         S_dbg_width_1280_seen;
    reg         S_dbg_height_720_seen;
    reg         S_dbg_isp_frame_seen_once;
    reg         S_dbg_isp_frame_repeat_seen;
    reg [1:0]   S_dbg_frame_repeat_sync;
    reg [1:0]   S_dbg_width_1280_sync;
    reg [1:0]   S_dbg_height_720_sync;
    reg [1:0]   S_dbg_isp_frame_repeat_sync;
    wire[3:0]   S_hdmi_debug_status;
    wire        S_lane_error_any;


    assign O_screen_pwm = 1'b1;
    assign S_video_out_vsync = ~S_hdmi_vsync;
	
	
    assign S_rst_n 		= S_pll_lock;
    assign S_hdmi_rst_n = S_pll_lock;

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_raw_seen <= 1'b0;
        else if(S_raw10_frame_start | S_axis_tvalid)
            S_dbg_raw_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_isp_seen <= 1'b0;
        else if(S_ISP_O_tuser | S_ISP_O_tvalid)
            S_dbg_isp_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_ddr_wr_seen <= 1'b0;
        else if(S_vi_ddr_wr_en)
            S_dbg_ddr_wr_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_ddr_rd_seen <= 1'b0;
        else if(S_ddr_user_rd_valid)
            S_dbg_ddr_rd_seen <= 1'b1;
    end

    always @(posedge S_24m_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_cam_cfg_seen <= 1'b0;
        else if(S_cam_cfg_done)
            S_dbg_cam_cfg_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_hs_seen <= 1'b0;
        else if(S_hs_rx_valid)
            S_dbg_hs_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_csi_seen <= 1'b0;
        else if(S_csi_frame_start | S_csi_valid)
            S_dbg_csi_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_raw10_seen <= 1'b0;
        else if(S_raw10_frame_start | S_raw10_valid)
            S_dbg_raw10_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_isp_fs_seen <= 1'b0;
        else if(S_ISP_O_tuser)
            S_dbg_isp_fs_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_isp_valid_seen <= 1'b0;
        else if(S_ISP_O_tvalid)
            S_dbg_isp_valid_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_ddr_req_seen <= 1'b0;
        else if(S_vi_ddr_wr_en)
            S_dbg_ddr_req_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_ddr_ready_seen <= 1'b0;
        else if(S_ddr_user_ready)
            S_dbg_ddr_ready_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_video_out_rst_n) begin
        if(!S_video_out_rst_n)
            S_dbg_rd_req_seen <= 1'b0;
        else if(S_vo_ddr_rd_en)
            S_dbg_rd_req_seen <= 1'b1;
    end

    // Count CSI payload words between HS packet boundaries.  This avoids
    // probing an internal net of csi_unpacket_2lane (which ChipWatcher cannot
    // legally connect to) and verifies the received line length externally.
    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n) begin
            S_dbg_hs_valid_d          <= 1'b0;
            S_dbg_csi_words           <= 11'd0;
            S_dbg_good_lines          <= 11'd0;
            S_dbg_frame_seen_once     <= 1'b0;
            S_dbg_frame_repeat_seen   <= 1'b0;
            S_dbg_width_1280_seen     <= 1'b0;
            S_dbg_height_720_seen     <= 1'b0;
            S_dbg_isp_frame_seen_once <= 1'b0;
            S_dbg_isp_frame_repeat_seen <= 1'b0;
        end
        else begin
            S_dbg_hs_valid_d <= S_hs_rx_valid;

            if(!S_dbg_hs_valid_d && S_hs_rx_valid)
                S_dbg_csi_words <= 11'd0;
            else if(S_csi_valid)
                S_dbg_csi_words <= S_dbg_csi_words + 11'd1;

            // A packet with CSI payload is an image line.  Ignore short
            // frame-start/frame-end packets, whose payload count is zero.
            if(S_dbg_hs_valid_d && !S_hs_rx_valid && (S_dbg_csi_words != 0)) begin
                if(S_dbg_csi_words == 11'd400) begin
                    S_dbg_width_1280_seen <= 1'b1;
                    S_dbg_good_lines <= S_dbg_good_lines + 11'd1;
                end
            end

            if(S_csi_frame_start) begin
                if(S_dbg_frame_seen_once) begin
                    S_dbg_frame_repeat_seen <= 1'b1;
                    if(S_dbg_good_lines == 11'd720)
                        S_dbg_height_720_seen <= 1'b1;
                end
                else
                    S_dbg_frame_seen_once <= 1'b1;
                S_dbg_good_lines <= 11'd0;
            end

            if(S_ISP_O_tuser) begin
                if(S_dbg_isp_frame_seen_once)
                    S_dbg_isp_frame_repeat_seen <= 1'b1;
                else
                    S_dbg_isp_frame_seen_once <= 1'b1;
            end
        end
    end

    always @(posedge S_ddr_clk or negedge S_video_out_rst_n) begin
        if(!S_video_out_rst_n)
            S_dbg_rd_valid_seen <= 1'b0;
        else if(S_ddr_user_rd_valid)
            S_dbg_rd_valid_seen <= 1'b1;
    end

    always @(posedge S_hdmi_pixel_clk or negedge S_video_out_rst_n) begin
        if(!S_video_out_rst_n)
            S_dbg_rd_nonzero_seen <= 1'b0;
        else if(S_hdmi_window_rd_en && (S_video_rd_data != 24'd0))
            S_dbg_rd_nonzero_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_mc_init_seen <= 1'b0;
        else if(S_init_calib_complete)
            S_dbg_mc_init_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_mc_app_rdy_seen <= 1'b0;
        else if(S_mc_dbg_app_rdy)
            S_dbg_mc_app_rdy_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_mc_wdf_rdy_seen <= 1'b0;
        else if(S_mc_dbg_wdf_rdy)
            S_dbg_mc_wdf_rdy_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_mc_cmd_pop_seen <= 1'b0;
        else if(S_mc_dbg_cmd_pop)
            S_dbg_mc_cmd_pop_seen <= 1'b1;
    end

    always @(posedge S_hdmi_pixel_clk or negedge S_hdmi_rst_n) begin
        if(!S_hdmi_rst_n) begin
            S_dbg_cam_cfg_seen_sync <= 2'b00;
            S_dbg_hs_seen_sync      <= 2'b00;
            S_dbg_csi_seen_sync     <= 2'b00;
            S_dbg_raw10_seen_sync   <= 2'b00;
            S_dbg_raw_seen_sync    <= 2'b00;
            S_dbg_isp_seen_sync    <= 2'b00;
            S_dbg_ddr_wr_seen_sync <= 2'b00;
            S_dbg_ddr_rd_seen_sync <= 2'b00;
            S_dbg_isp_fs_seen_sync  <= 2'b00;
            S_dbg_isp_valid_seen_sync <= 2'b00;
            S_dbg_ddr_req_seen_sync <= 2'b00;
            S_dbg_ddr_ready_seen_sync <= 2'b00;
            S_dbg_video_nonzero_seen <= 1'b0;
            S_dbg_rd_req_seen_sync <= 2'b00;
            S_dbg_rd_valid_seen_sync <= 2'b00;
            S_dbg_rd_nonzero_seen_sync <= 2'b00;
            S_dbg_mc_init_seen_sync <= 2'b00;
            S_dbg_mc_app_rdy_seen_sync <= 2'b00;
            S_dbg_mc_wdf_rdy_seen_sync <= 2'b00;
            S_dbg_mc_cmd_pop_seen_sync <= 2'b00;
            S_dbg_frame_repeat_sync <= 2'b00;
            S_dbg_width_1280_sync <= 2'b00;
            S_dbg_height_720_sync <= 2'b00;
            S_dbg_isp_frame_repeat_sync <= 2'b00;
        end
        else begin
            S_dbg_cam_cfg_seen_sync <= {S_dbg_cam_cfg_seen_sync[0], S_dbg_cam_cfg_seen};
            S_dbg_hs_seen_sync      <= {S_dbg_hs_seen_sync[0],      S_dbg_hs_seen};
            S_dbg_csi_seen_sync     <= {S_dbg_csi_seen_sync[0],     S_dbg_csi_seen};
            S_dbg_raw10_seen_sync   <= {S_dbg_raw10_seen_sync[0],   S_dbg_raw10_seen};
            S_dbg_raw_seen_sync    <= {S_dbg_raw_seen_sync[0],    S_dbg_raw_seen};
            S_dbg_isp_seen_sync    <= {S_dbg_isp_seen_sync[0],    S_dbg_isp_seen};
            S_dbg_ddr_wr_seen_sync <= {S_dbg_ddr_wr_seen_sync[0], S_dbg_ddr_wr_seen};
            S_dbg_ddr_rd_seen_sync <= {S_dbg_ddr_rd_seen_sync[0], S_dbg_ddr_rd_seen};
            S_dbg_isp_fs_seen_sync  <= {S_dbg_isp_fs_seen_sync[0],  S_dbg_isp_fs_seen};
            S_dbg_isp_valid_seen_sync <= {S_dbg_isp_valid_seen_sync[0], S_dbg_isp_valid_seen};
            S_dbg_ddr_req_seen_sync <= {S_dbg_ddr_req_seen_sync[0], S_dbg_ddr_req_seen};
            S_dbg_ddr_ready_seen_sync <= {S_dbg_ddr_ready_seen_sync[0], S_dbg_ddr_ready_seen};
            S_dbg_rd_req_seen_sync <= {S_dbg_rd_req_seen_sync[0], S_dbg_rd_req_seen};
            S_dbg_rd_valid_seen_sync <= {S_dbg_rd_valid_seen_sync[0], S_dbg_rd_valid_seen};
            S_dbg_rd_nonzero_seen_sync <= {S_dbg_rd_nonzero_seen_sync[0], S_dbg_rd_nonzero_seen};
            S_dbg_mc_init_seen_sync <= {S_dbg_mc_init_seen_sync[0], S_dbg_mc_init_seen};
            S_dbg_mc_app_rdy_seen_sync <= {S_dbg_mc_app_rdy_seen_sync[0], S_dbg_mc_app_rdy_seen};
            S_dbg_mc_wdf_rdy_seen_sync <= {S_dbg_mc_wdf_rdy_seen_sync[0], S_dbg_mc_wdf_rdy_seen};
            S_dbg_mc_cmd_pop_seen_sync <= {S_dbg_mc_cmd_pop_seen_sync[0], S_dbg_mc_cmd_pop_seen};
            S_dbg_frame_repeat_sync <= {S_dbg_frame_repeat_sync[0], S_dbg_frame_repeat_seen};
            S_dbg_width_1280_sync <= {S_dbg_width_1280_sync[0], S_dbg_width_1280_seen};
            S_dbg_height_720_sync <= {S_dbg_height_720_sync[0], S_dbg_height_720_seen};
            S_dbg_isp_frame_repeat_sync <= {S_dbg_isp_frame_repeat_sync[0], S_dbg_isp_frame_repeat_seen};
            if(S_hdmi_window_rd_en && (S_video_rd_data != 24'd0))
                S_dbg_video_nonzero_seen <= 1'b1;
        end
    end

    assign S_lane_error_any = |S_lane_error;

    assign S_vo_dbg_fifo_rst = 1'b0;
    assign S_vo_dbg_ddr_rd_valid = 1'b0;
    assign S_vo_dbg_fifo_rd_en = 1'b0;
    assign S_vo_dbg_fifo_empty = 1'b0;
    assign S_mc_dbg_fifo_afull = 1'b0;
    assign S_mc_dbg_app_rdy = 1'b0;
    assign S_mc_dbg_wdf_rdy = 1'b0;
    assign S_mc_dbg_cmd_pop = 1'b0;

    // On-screen bring-up status, from left to right in DEBUG_MODE=3:
    // I2C configuration completed, MIPI HS activity seen, repeated CSI frames,
    // and a 1280-pixel RAW10 line (400 x 32-bit CSI payload words) seen.
    assign S_hdmi_debug_status = {
        S_dbg_width_1280_sync[1],
        S_dbg_frame_repeat_sync[1],
        S_dbg_hs_seen_sync[1],
        S_dbg_cam_cfg_seen_sync[1]
    };
	
    // ------------------------------------------------------------------
    //  ★ 2026-10-21 换 SC520CS：新增上电时序
    //  厂商例程（design_top_wrapper.v:507）：PLL 锁定后先把传感器的
    //  PWDNB/XSHUTDN 拉低 >=1 ms，再拉高；从拉高起再等 >=5 ms 才做
    //  第一次 I2C。SC500 没有这个要求（原来这里直接 assign O_cam_rst = 1'b1）。
    //  节奏参数按 23.81 MHz 的 pll_clk_24m 折算，与厂商例程同值。
    // ------------------------------------------------------------------
    localparam integer CAM_PWDNB_LOW_CYCLES = 23810;   // >= 1 ms @ 23.81 MHz
    localparam integer CAM_I2C_START_CYCLES = 142857;  // 释放 + >= 5 ms
    reg  [17:0] S_cam_power_cnt;
    reg         S_cam_pwdnb;
    reg         S_cam_i2c_ready;
    wire [15:0] S_cam_sensor_id;
    wire        S_cam_sensor_id_ok;
    wire        S_cam_iic_error;

    always @(posedge S_24m_clk or negedge S_pll_lock) begin
        if (!S_pll_lock) begin
            S_cam_power_cnt <= 18'd0;
            S_cam_pwdnb     <= 1'b0;
            S_cam_i2c_ready <= 1'b0;
        end else begin
            if (S_cam_power_cnt < CAM_I2C_START_CYCLES)
                S_cam_power_cnt <= S_cam_power_cnt + 1'b1;
            if (S_cam_power_cnt >= CAM_PWDNB_LOW_CYCLES)
                S_cam_pwdnb <= 1'b1;
            if (S_cam_power_cnt >= CAM_I2C_START_CYCLES - 1)
                S_cam_i2c_ready <= 1'b1;
        end
    end

    assign O_cam_rst = S_cam_pwdnb;
    assign O_cam_24m 	= S_24m_clk;
	
	
	
	
    PLL u_PLL(
        .refclk      ( I_sys_clk         ),
        .reset    	 ( ~I_rst_n          ),
        
        .clk0_out    ( S_100m_clk        ),
        .clk1_out    ( S_24m_clk         ),

        .clk4_out    ( S_hdmi_pixel_clk  ),
        .clk5_out    ( S_hdmi_serial_clk ),

        .lock        ( S_pll_lock        )

    );


	

  
// ============================================================================
// lab_ex4 新增：按键长短按判别 + 模式寄存器 + AE 门控
// ----------------------------------------------------------------------------
// 契约：doc/arch/interface_contract.yaml -> modules_new.key_mode_ctrl
// 时钟：D1 (pll_clk_24m, 实测 23.810 MHz)
//
//   ★ 2026-09-20 红线1 改造后的语义（**两位现在是一个整体模式号**）：
//
//   O_mode[1:0] : 图像处理模式 0=原图 1=灰度 2=二值化 3=反色
//                   -> isp_top.I_img_mode      (D1 -> D2 同步 + 帧首锁存)
//                   -> hdmi_mixer.I_mode_disp  (D1 -> D4 同步，OSD 显示同一模式号)
//   O_btn_ae    : 门控后按键(低有效) -> ae_set.I_btn[3:2]
//
//   ⚠ 改造前是"bit0=边缘检测使能 / bit1=OSD 使能"两位语义不同；
//     现在两位只表示模式号，OSD 使能已改为**恒开**
//     （见 u_hdmi_mixer 的 .I_osd_en(1'b1)）——
//     否则模式号的高位会让 OSD 只在模式 2/3 出现，
//     模式 0/1 时"安路 Logo"消失，会违反基础要求④。
//
//   ⚠ 之所以把 mode[1:0] 同时送给算法通路与 OSD，是为了让
//     "屏幕上显示的模式数字"与"实际生效的算法"永远一致，
//     避免出现"显示灰度、实际二值化"这类难以现场排查的错配。
//
// 长按(>=500ms)不切模式，把按键透给 ae_set 做 AE 增益调节；
// 短按(<500ms)切模式，门控输出恒 2'b11 使 ae_set 看不到按键。
// ============================================================================
key_mode_ctrl #(
    .CLK_FREQ_HZ  ( 23810000 ),
    .DEBOUNCE_MS  ( 20       ),
    .LONGPRESS_MS ( 500      )
) u_key_mode_ctrl (
    .I_clk     ( S_24m_clk      ),
    .I_rst_n   ( S_rst_n        ),
    .I_button  ( I_button       ),
    .O_mode    ( S_mode_24      ),
    .O_btn_ae  ( S_ae_btn_gated ),
    .O_auto_tog( S_auto_tog     )   // ★ P6：短按 KEY2 → AE 自动/手动切换
);

// ---- ★ P6：AE 自动/手动开关 ----
//   **上电即自动**（复位值 1）—— 这是 P6 的交付语义："光线剧烈变化时工作正常"
//   不需要人去按键。短按 KEY2 才切到手动（保留原有手动调节作为回退/对比手段）。
//   按键手势分工（互不冲突，且状态都在 OSD 上可观测）：
//       短按 KEY1 : 切换图像模式 0→1→2→3→4→0
//       长按 KEY1 : （透给 ae_set）手动调 AE/AG
//       短按 KEY2 : **切换 AE 自动 / 手动**   ← P6 新增
//       长按 KEY2 : （透给 ae_set）手动调 AE/AG
always @(posedge S_24m_clk or negedge S_rst_n) begin
    if (!S_rst_n) S_ae_auto <= 1'b1;                 // 上电即自动
    else if (S_auto_tog) S_ae_auto <= ~S_ae_auto;
end

// ============================================================================
//  ★ 扩展(3)：识别结果 → 外部控制（板载 LED + 蜂鸣器）
// ----------------------------------------------------------------------------
//  这一条要求的原文是"面向实际应用场景，**根据识别结果实现外部控制**"，
//  并且赛题二**只有这一条允许额外的处理器/外设**。
//  识别结果是 P5 的 `O_tgt_valid` / `O_tgt_shape`，本模块把它们变成人看得见、
//  听得见的东西 —— 这是"识别真的在工作"最直接的**外部**证据（不依赖显示器）。
//
//  LED 语义（四个独立 LED，都能单独观察）：
//     LED1 (D10)：**检出目标**  ← 要求本体
//     LED2 (E10)：形状 = BAR（长条）
//     LED3 (C6) ：形状 = BLOCK（块状）—— 与 LED2 互斥，两者都不亮 = 无目标
//     LED4 (D6) ：**AE 处于自动模式**（P6）—— 一眼看出闭环有没有在跑
//
//  ★ 为什么（LED/蜂鸣器）直接用 HDMI 域的值，而不先同步到 24 MHz 域：
//     ① `S_tgt_valid_h`/`S_tgt_shape_h`/`S_ae_auto_h` **本来就是 HDMI 域的保持寄存器**
//        （P5/P6 的跨域捕获结果，每帧最多变一次）；
//     ② 若再同步回 24 MHz 域，就会**新增一条 HDMI→24M 的跨域路径**，而本工程的 SDC
//        把 `pll_clk_24m` 与 `HDMI_PIXEL_CLK` 放在**同一个时钟组**（按同步关系分析），
//        现有 `set_false_path` 只覆盖 24M→HDMI 那一个方向 ⇒ 会凭空多出一条违规路径。
//     ③ 就地驱动 ⇒ **跨域数为 0、不动任何约束**，而且 LED 与 OSD 显示的必然是同一份数据。
//
//  ★ 蜂鸣器：0.15 s 响 / 0.35 s 停，约 2.7 kHz —— 比长鸣好听，也比长鸣省电。
//     板上 SW5 是蜂鸣器使能开关，演示前要拨到 ON（否则听不到，容易被误判成"没做"）。
// ============================================================================
always @(posedge S_hdmi_pixel_clk or negedge S_hdmi_rst_n) begin
    if (!S_hdmi_rst_n) begin
        S_led_r  <= 4'd0;
        S_tone_c <= 14'd0;
        S_tone   <= 1'b0;
        S_buzz_c <= 26'd0;
    end else begin
        // ---- LED：纯粹是既有信号的"可见化"，无任何新逻辑 ----
        S_led_r[0] <= S_tgt_valid_h;                            // 检出目标
        S_led_r[1] <= S_tgt_valid_h && (S_tgt_shape_h == 2'd1); // BAR
        S_led_r[2] <= S_tgt_valid_h && (S_tgt_shape_h == 2'd2); // BLOCK
        S_led_r[3] <= S_ae_auto_h;                              // AE 自动模式（与 OSD 首字符同源）

        // ---- 音调：每 TONE_HALF 拍翻转一次 ⇒ 方波 ≈ 2.70 kHz ----
        if (S_tone_c >= TONE_HALF - 1) begin
            S_tone_c <= 14'd0;
            S_tone   <= ~S_tone;
        end else begin
            S_tone_c <= S_tone_c + 14'd1;
        end

        // ---- 间歇：一个 BUZZ_PER 周期里只在开头 BUZZ_ON 期间放音 ----
        if (S_buzz_c >= BUZZ_PER - 1) S_buzz_c <= 26'd0;
        else                          S_buzz_c <= S_buzz_c + 26'd1;
    end
end
assign O_led    = S_led_r;
assign O_buzzer = S_tgt_valid_h && S_tone && (S_buzz_c < BUZZ_ON);

// ---- D1 -> D2 同步：图像处理模式 mode[1:0]（★ 红线1 由 1 位扩为 2 位）----
//
// 为什么不能简单地把原来那 1 位同步器加宽就完事：
//   mode[1:0] 是**多比特**信号，两个比特各自过 2 级触发器时到达时刻可能不同，
//   于是可能**瞬间采到中间态**（例：01 -> 10 切换途中采到 11 = 反色），
//   在 75 MHz 的 CSI 域里就是一个可见的错误画面。
//
// 处理办法（两级防护）：
//   ① 两位分别 2-FF 同步（`_s1/_s2`），**同组复制**，不拆散；
//   ② 再把同步后的值**只在帧首（I_tuser）锁存一次**（`_r0/_r1`）：
//        - 帧首锁存 => 算法模式**不会在一帧中间变化**（否则该帧会半帧灰度半帧二值）；
//        - tuser 是单比特、每帧一次的脉冲 => **多比特 CDC 最坏只影响那一帧的锁存**，
//          绝不会把中间态持续带进数据通路。
//   代价：按键切换后**下一帧才生效**（1 帧 ≈ 16.7 ms，人眼不可察）。
//
// 注意 tuser 极性：isp_top 内的 awb/signal_delay 用 `I_tuser` 作**高有效**帧首
//   （见 signal_delay.v:61/73），本处用的 `S_raw_tuser` 正是 isp_top.I_tuser
//   的同一根线，故用 `S_raw_tuser ? 0` 保持一致。极性若反，模式切换会延迟一帧生效。
reg [2:0] S_mode_csi_s1, S_mode_csi_s2;
reg [2:0] S_mode_csi_r0, S_mode_csi_r1;
always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
    if(!S_rst_n) begin
        S_mode_csi_s1 <= 3'b000;
        S_mode_csi_s2 <= 3'b000;
        S_mode_csi_r0 <= 3'b000;
        S_mode_csi_r1 <= 3'b000;
    end else begin
        S_mode_csi_s1 <= S_mode_24;          // ① 2-FF 同步（两位同组）
        S_mode_csi_s2 <= S_mode_csi_s1;
        if (S_raw_tuser)                      // ② 帧首清零
            S_mode_csi_r0 <= 3'b000;
        else
            S_mode_csi_r0 <= S_mode_csi_s2;   //    帧中跟踪
        S_mode_csi_r1 <= S_mode_csi_r0;       //    帧首那一拍被锁住
    end
end
assign S_mode_csi = S_mode_csi_r1;

// ---- D1 -> D4 同步：mode[1:0] ----
// **两位必须同组同步**，禁止拆成两个独立同步器，否则 OSD 使能与模式数字可能不同拍
reg [2:0] S_mode_hdmi_s1, S_mode_hdmi_s2;
always @(posedge S_hdmi_pixel_clk or negedge S_rst_n) begin
    if(!S_rst_n) begin
        S_mode_hdmi_s1 <= 3'b000;
        S_mode_hdmi_s2 <= 3'b000;
    end else begin
        S_mode_hdmi_s1 <= S_mode_24;
        S_mode_hdmi_s2 <= S_mode_hdmi_s1;
    end
end
assign S_mode_hdmi = S_mode_hdmi_s2;


  ae_set u_ae_set (
      .I_clk(S_24m_clk),
      .I_rst(~S_rst_n),
      .I_btn({S_ae_btn_gated,2'b11}),   // lab_ex4: 由 I_button 改为门控后按键
      .I_cam_cfg_done(S_cam_cfg_done),
      .I_ae_cfg_done(S_ae_cfg_done),
      // ---- ★ P6：自动 / 手动双模 ----
      .I_auto_en ( S_ae_auto        ),   // 1 = 自动（由 u_ae_ctrl 给目标）
      .I_ae_auto ( S_ae_auto_ae     ),
      .I_ag_auto ( S_ae_auto_ag     ),
      .I_ag_max  ( AE_AG_MAX        ),   // 手动 AG 上限 = 自动 AG 上限（保证一致）
      .O_ae_req(S_ae_req),
      .O_ae(S_ae),
      .O_ag(S_ag)
  );
  // 已生效值回读（跨到自动控制器做"无缝衔接"与"命令不堆积"判断）
  assign S_ae_cur = S_ae;
  assign S_ag_cur = S_ag;

  // ==========================================================================
  //  ★ P6：AE 闭环控制器（24 MHz 域，与 ae_set / I2C 同域）
  //    输入：ISP 域每帧一组亮度统计（准静态多比特 + 翻转标志，跨域在本模块内做）
  //    输出：自动目标 AE / AG（送给 ae_set；手动模式下 ae_set 不采用）
  //    详见 ae_ctrl.v 头注释（控制律、优先级、硬件天花板）。
  // ==========================================================================
  ae_ctrl #(
      .IMG_WIDTH   ( 1280 ),
      .IMG_HEIGHT  ( 720  ),
      .TARGET_LUMA ( 8'd112 ),
      .DZ_PCT      ( 3    ),
      .AE_MIN      ( 16'd2    ),
      .AE_MAX      ( AE_AE_MAX ),
      .AG_MIN      ( 16'd16   ),
      .AG_MAX      ( AE_AG_MAX ),
      .AG_INIT     ( 16'd144  ),
      .CLIP_PCT    ( 2    ),
      .THROTTLE    ( 2    )
  ) u_ae_ctrl (
      .I_clk        ( S_24m_clk     ),
      .I_rst_n      ( S_rst_n       ),
      .I_stats_sum  ( S_ae_sum      ),
      .I_stats_clip ( S_ae_clip     ),
      .I_stats_tog  ( S_ae_tog      ),
      .I_ae_cur     ( S_ae_cur      ),
      .I_ag_cur     ( S_ag_cur      ),
      .I_auto_en    ( S_ae_auto     ),
      .O_ae         ( S_ae_auto_ae  ),
      .O_ag         ( S_ae_auto_ag  ),
      .O_avg_sum    (               ),
      .O_avg_luma   ( S_ae_avg_24   ),
      .O_clip_luma  ( S_ae_clip_24  ),
      .O_dir        ( S_ae_dir      ),
      .O_upd_cnt    ( S_ae_upd_cnt  ),
      .O_sat        ( S_ae_sat      ),
      .O_new_frame  ( S_ae_new_frame)
  );
  
    uicfgcs520 #(
      .CLK_DIV(23809524 / 100000 - 1)
  ) u_uicfgcs520 (
      .I_clk(S_24m_clk),               // 系统时钟输入
      .I_rst_n(S_cam_i2c_ready),       // SC520CS: 上电时序完成后才允许 I2C
      .I_ae_req(S_ae_req),
      .I_ae(S_ae),
      .I_ag(S_ag),
      .O_cam_scl(O_cam_scl),           // I2C 总线 SCL
      .IO_cam_sda(IO_cam_sda),         // I2C 总线 SDA
      .O_cfg_done(S_cam_cfg_done),     // 寄存器初始化完成
      .O_ae_cfg_done(S_ae_cfg_done),   // AE 配置完成
      .O_sensor_id(S_cam_sensor_id),   // ★ SC520 新增：读回的芯片 ID
      .O_sensor_id_ok(S_cam_sensor_id_ok),
      .O_iic_error(S_cam_iic_error)
  );
	
    mipi_dphy_rx_ph1p_mipiio_wrapper#(
        .DPHY_RX_LOCATION      ( "DPHY0" ),
        .HS_EQUALIZER          ( "3dB"   ),//"0dB","1.5dB","3dB","4.5dB","6dB","7.5dB","9dB","10.5dB"
        .HS_VGA_GAIN           ( "8dB" ),//"-3dB","-1.5dB","0dB","1.5dB","3dB","4.5dB","6dB","7.5dB"
        .LANE_NUM              ( 2       ),
        .BYTE_NUM              ( 1       )
    )u_mipi_dphy_rx_ph1p_mipiio_wrapper(
        .I_lp_clk              ( S_100m_clk       ),
        .I_rst                 ( ~S_rst_n         ),

        .I_clk_lane_in_delay   ( 6'd0             ),
        .I_data_lane0_in_delay ( 6'd0             ),
        .I_data_lane1_in_delay ( 6'd0             ),
        .I_data_lane2_in_delay ( 6'd0             ),
        .I_data_lane3_in_delay ( 6'd0             ),

        .I_lane_invert         ( 4'b0000          ),
     
        .O_hs_rx_clk           ( S_csi_rx_clk     ),
        .O_hs_rx_valid         ( S_hs_rx_valid    ),
        .O_hs_rx_data          ( S_hs_rx_data     ),
      
        .O_lp_rx_lane0_p       (  ),
        .O_lp_rx_lane0_n       (  ),
      
        .I_lp_tx_en            ( 1'b0             ),
        .I_lp_tx_lane0_p       ( 1'b1             ),
        .I_lp_tx_lane0_n       ( 1'b1             ),
      
        .O_lane_match_error    (                  ),
        .O_lane_error          ( S_lane_error     ),
      
        .IO_rx_clk_pad_n       ( IO_rx_clk_pad_n  ),
        .IO_rx_clk_pad_p       ( IO_rx_clk_pad_p  ),
        .IO_rx_data_pad_n      ( IO_rx_data_pad_n ),
        .IO_rx_data_pad_p      ( IO_rx_data_pad_p )
    );
	
	
 //  cwc cwc_inst
 //(
 //    .probe0(S_hs_rx_valid),
 //    .probe1(S_hs_rx_data),
 //    .probe2(S_lane_error),
 //    .clk(S_csi_rx_clk)
 //);

 //csi 解码为RAW数据
csi_unpacket_2lane u_csi_unpacket(
.I_clk                 ( S_csi_rx_clk       ),
.I_rst_n               ( S_rst_n        	),
.I_hs_valid            ( S_hs_rx_valid     ),
.I_hs_data             ( S_hs_rx_data      ),

.O_csi_frame_start     ( S_csi_frame_start ),
.O_csi_frame_end       ( S_csi_frame_end   ),
.O_csi_valid           ( S_csi_valid       ),
.O_csi_data            ( S_csi_data        )
);


//解码为RAW8
raw10_unpacket_2lane u_raw10_unpacket (
.I_clk  (S_csi_rx_clk),
.I_rst_n(S_rst_n),

.I_csi_frame_start(S_csi_frame_start),
.I_csi_frame_end  (S_csi_frame_end),
.I_csi_valid      (S_csi_valid),
.I_csi_data       (S_csi_data),

.O_raw10_frame_start(S_raw10_frame_start),
.O_raw10_frame_end  (S_raw10_frame_end),
.O_raw10_valid      (S_raw10_valid),
.O_raw10_data       (S_raw10_data)
  );


//将数据转为stream流
uial2axis #(
.IMG_WIDTH(1280),
.IMG_HEIGHT(720),
.INPUT_DATA_WIDTH(40)
) 
u_uial2axis (
.I_native_clk(S_csi_rx_clk),
.I_rst_n     (S_rst_n),
.I_data      (S_raw10_data       ),
.I_data_valid(S_raw10_valid      ),
.I_data_start(S_raw10_frame_start),
.I_data_end  (S_raw10_frame_end  ),
.axis_tvalid (S_axis_tvalid),
.axis_tdata  (S_axis_tdata ),
.axis_tuser  (S_axis_tuser ),
.axis_tlast  (S_axis_tlast )
);
	

// SC500 factory HD mode already outputs native 1280x720 RAW10.
assign S_raw_tdata  = S_axis_tdata;
assign S_raw_tvalid = S_axis_tvalid;
assign S_raw_tlast  = S_axis_tlast;
assign S_raw_tuser  = S_axis_tuser;


//cwc1 cwc1_Inst
//  (
//      .probe0(S_axis_tuser),
//      .probe1(S_axis_tvalid),
//      .probe2(S_axis_tlast),
//      .probe3(S_axis_tdata),
//      .probe4(S_ISP_O_tuser),
//      .probe5(S_ISP_O_tvalid),
//      .probe6(S_ISP_O_tlast),
//      .probe7(S_ISP_O_tdata),
//      .probe8 (S_raw_tdata ),
//      .probe9 (S_raw_tlast ),
//      .probe10(S_raw_tvalid),
//      .probe11(S_raw_tuser ),
//      .clk(S_csi_rx_clk)
//  );


//ISP算法顶层模块
isp_top u_isp_top (
.axi4s_video_aclk(S_csi_rx_clk),
.I_rst_n         (S_rst_n),
.I_tlast         (S_raw_tlast	),
.I_tuser         (S_raw_tuser	),
.I_tdata         (S_raw_tdata	),
.I_tvalid        (S_raw_tvalid	),
.I_tdest         (),
.I_img_mode      (S_mode_csi),          // ★ P4：0 原图/1 灰度/2 二值化/3 反色/4 卡通（D2 域）
.I_img_threshold (8'd128),              // 二值化阈值，固定 128（中值）
.I_cartoon_th    (8'd20),               // ★ P4/P5：卡通形态学梯度阈值（越大边缘越少）；40→20 对齐参考实现的边缘灵敏度
.O_tready        (S_ISP_O_tready),
.O_tdata         (S_ISP_O_tdata ),
.O_tlast         (S_ISP_O_tlast ),
.O_tuser         (S_ISP_O_tuser ),
.O_tvalid        (S_ISP_O_tvalid),
.I_tready        (),
// ★ P5：颜色目标检测结果（ISP 域）
.O_tgt_x_min     (S_tgt_x_min),
.O_tgt_x_max     (S_tgt_x_max),
.O_tgt_y_min     (S_tgt_y_min),
.O_tgt_y_max     (S_tgt_y_max),
.O_tgt_tiles     (S_tgt_tiles),
.O_tgt_shape     (S_tgt_shape),
.O_tgt_valid     (S_tgt_valid),
.O_tgt_frame     (S_tgt_frame),
.O_tgt_x_d3      (S_tgt_x_d3),
.O_tgt_x_d2      (S_tgt_x_d2),
.O_tgt_x_d1      (S_tgt_x_d1),
.O_tgt_x_d0      (S_tgt_x_d0),
.O_tgt_y_d2      (S_tgt_y_d2),
.O_tgt_y_d1      (S_tgt_y_d1),
.O_tgt_y_d0      (S_tgt_y_d0),
.O_tgt_dbg_beat  (S_tgt_dbg_beat),
.O_tgt_dbg_warm  (S_tgt_dbg_warm),
.O_tgt_dbg_cb    (S_tgt_dbg_cb),
.O_tgt_dbg_cr    (S_tgt_dbg_cr),
// ★ P6：每帧亮度统计（ISP 域 → 24 MHz 域，跨域在 u_ae_ctrl 内用
//        "2-FF 同步 + 翻转标志边沿捕获"完成）
//        ⚠ 平均亮度不在这里传：它在 u_ae_ctrl（24 MHz 域）里由 ΣY 算出
.O_ae_sum        (S_ae_sum),
.O_ae_clip       (S_ae_clip),
.O_ae_tog        (S_ae_tog),
// ★ P7：运动检测（跨域在本文件下方做）
.O_mot_x_min     (S_mot_x_min),
.O_mot_x_max     (S_mot_x_max),
.O_mot_y_min     (S_mot_y_min),
.O_mot_y_max     (S_mot_y_max),
.O_mot_blkcnt    (S_mot_blkcnt),
.O_mot_valid     (S_mot_valid),
.O_mot_global    (S_mot_global),
.O_mot_frame     (S_mot_frame)
  );


    video_in u_video_in(
        .I_rst_n              (  S_rst_n             ),

        .I_camera_clk         ( S_csi_rx_clk          ),
        .I_camera_frame_start ( S_ISP_O_tuser  ),
        .I_camera_valid       ( S_ISP_O_tvalid ),
        .I_camera_data        ( S_ISP_O_tdata  ),
        .I_mipi_rx_error      ( 1'b0			      ),

        .I_ddr_clk            ( S_ddr_clk             ),
		.I_display_pause      ( 1'b0                  ),
        .I_video_out_rd_busy  ( S_video_out_rd_busy   ),
        .O_video_in_wr_busy   ( S_video_in_wr_busy    ),
        .O_video_out_rp       ( S_video_out_rp        ),
        .O_video_in_wp        ( S_video_in_wp         ),   // ★ P3：写 BANK
        .O_video_in_frame_start( S_video_in_frame_start),  // ★ P3：采集帧写入起始

        .O_ddr_user_wr_en     ( S_vi_ddr_wr_en        ),
        .O_ddr_user_addr      ( S_vi_ddr_wr_addr      ),
        .O_ddr_user_wr_data   ( S_vi_ddr_wr_data      ),
        .I_ddr_user_ready     ( S_ddr_user_ready      )
    );



    assign S_ddr_user_wr_en    = S_vi_ddr_wr_en;

    assign S_ddr_user_rd_en    = S_vo_ddr_rd_en;

    assign S_ddr_user_addr     = S_vi_ddr_wr_en ? S_vi_ddr_wr_addr :
                                 S_vo_ddr_rd_en ? S_vo_ddr_rd_addr : 'd0;

    assign S_ddr_user_wr_data  = S_vi_ddr_wr_data;


    assign S_video_out_rst_n = S_hdmi_rst_n;

    video_out u_video_out(
        .I_rst_n             ( S_video_out_rst_n    ),
        .I_ddr_clk           ( S_ddr_clk            ),
 
        .O_video_out_rd_busy ( S_video_out_rd_busy  ),
        .I_video_in_wr_busy  ( S_video_in_wr_busy   ),
        .I_video_out_rp      ( S_video_out_rp       ),
 
        .O_ddr_user_rd_en    ( S_vo_ddr_rd_en       ),
        .O_ddr_user_addr     ( S_vo_ddr_rd_addr     ),
        .I_ddr_user_ready    ( S_ddr_user_ready     ),
        .I_ddr_user_rd_valid ( S_ddr_user_rd_valid  ),
        .I_ddr_user_rd_data  ( S_ddr_user_rd_data   ),

        .I_dsi_clk           ( S_hdmi_pixel_clk     ),
        .I_video_vsync       ( S_video_out_vsync    ),
        .I_video_rd_en       ( S_hdmi_window_rd_en  ),
        .O_video_frame_start ( S_video_frame_start  ),  // ★ P3：显示帧起始
        .O_vdieo_data        ( S_video_rd_data      )
    );



    mc_to_user_interface u_mc_to_user_interface(
        .I_clk                   ( S_ddr_clk               ),
        .I_rst_n                 ( S_rst_n                 ),

        .I_ddr_user_wr_en        ( S_ddr_user_wr_en        ),
        .I_ddr_user_rd_en        ( S_ddr_user_rd_en        ),
        .I_ddr_user_addr         ( S_ddr_user_addr         ),
        .I_ddr_user_wr_data      ( S_ddr_user_wr_data      ),
        .O_ddr_user_ready        ( S_ddr_user_ready        ),
        .O_ddr_user_rd_valid     ( S_ddr_user_rd_valid     ),
        .O_ddr_user_rd_data      ( S_ddr_user_rd_data      ),
            
        .O_mc_app_en             ( S_mc_app_en             ),
        .O_mc_app_addr           ( S_mc_app_addr           ),
        .O_mc_app_cmd            ( S_mc_app_cmd            ),
        .I_mc_app_rdy            ( S_mc_app_rdy            ),
        .O_mc_app_wdf_wren       ( S_mc_app_wdf_wren       ),
        .O_mc_app_wdf_data       ( S_mc_app_wdf_data       ),
        .O_mc_app_wdf_end        ( S_mc_app_wdf_end        ),
        .O_mc_app_wdf_mask       ( S_mc_app_wdf_mask       ),
        .I_mc_app_wdf_rdy        ( S_mc_app_wdf_rdy        ),
        .I_mc_app_rd_data        ( S_mc_app_rd_data        ),
        .I_mc_app_rd_data_end    ( S_mc_app_rd_data_end    ),
        .I_mc_app_rd_data_valid  ( S_mc_app_rd_data_valid  )
    );



    ph1p35_324_ddr_wrapper u_ph1p35_324_ddr_wrapper(
        .I_sys_clk              ( I_sys_clk              ),
        .I_sys_rst_n            ( S_rst_n                ),

        .O_ddr_clk              ( S_ddr_clk              ),
        .O_init_calib_complete  ( S_init_calib_complete  ),
        .I_mc_app_addr          ( S_mc_app_addr          ),
        .I_mc_app_cmd           ( S_mc_app_cmd           ),
        .I_mc_app_en            ( S_mc_app_en            ),
        .I_mc_app_wdf_data      ( S_mc_app_wdf_data      ),
        .I_mc_app_wdf_end       ( S_mc_app_wdf_end       ),
        .I_mc_app_wdf_mask      ( S_mc_app_wdf_mask      ),
        .I_mc_app_wdf_wren      ( S_mc_app_wdf_wren      ),
        .O_mc_app_rd_data       ( S_mc_app_rd_data       ),
        .O_mc_app_rd_data_end   ( S_mc_app_rd_data_end   ),
        .O_mc_app_rd_data_valid ( S_mc_app_rd_data_valid ),
        .O_mc_app_rdy           ( S_mc_app_rdy           ),
        .O_mc_app_wdf_rdy       ( S_mc_app_wdf_rdy       ),

        .ddr_addr               ( ddr_addr               ),
        .ddr_ba                 ( ddr_ba                 ),
        .ddr_cke                ( ddr_cke                ),
        .ddr_odt                ( ddr_odt                ),
        .ddr_cs_n               ( ddr_cs_n               ),
        .ddr_ras_n              ( ddr_ras_n              ),
        .ddr_cas_n              ( ddr_cas_n              ),
        .ddr_we_n               ( ddr_we_n               ),
        .ddr_ck_p               ( ddr_ck_p               ),
        .ddr_ck_n               ( ddr_ck_n               ),
        .ddr_dm                 ( ddr_dm                 ),
        .ddr_dq                 ( ddr_dq                 ),
        .ddr_dqs_p              ( ddr_dqs_p              ),
        .ddr_dqs_n              ( ddr_dqs_n              )
    );



    uivtc #(
        .H_ActiveSize ( 1280 ),
        .H_FrameSize  ( 1650 ),
        .H_SyncStart  ( 1390 ),
        .H_SyncEnd    ( 1430 ),
        .V_ActiveSize ( 720  ),
        .V_FrameSize  ( 750  ),
        .V_SyncStart  ( 725  ),
        .V_SyncEnd    ( 730  )
    )u_hdmi_vtc(
        .I_vtc_rstn    ( S_hdmi_rst_n    ),
        .I_vtc_clk     ( S_hdmi_pixel_clk ),
        .O_vtc_vs      ( S_hdmi_vsync     ),
        .O_vtc_hs      ( S_hdmi_hsync     ),
        .O_vtc_de_valid( S_hdmi_de        ),
        .O_vtc_user    ( S_hdmi_user      ),
        .O_vtc_last    ( S_hdmi_last      )
    );

    hdmi_mixer #(
        .H_OFFSET   ( 0    ),
        .V_OFFSET   ( 0    ),
        .IMG_WIDTH  ( 1280 ),
        .IMG_HEIGHT ( 720  ),
        .DEBUG_MODE ( 0    ) // Normal SC500 1280x720 camera image
    )u_hdmi_mixer(
        .I_clk           ( S_hdmi_pixel_clk   ),
        .I_rst_n         ( S_hdmi_rst_n       ),
        .I_video_vsync   ( S_hdmi_vsync       ),
        .I_video_hsync   ( S_hdmi_hsync       ),
        .I_video_de      ( S_hdmi_de          ),
        .I_video_user    ( S_hdmi_user        ),
        .I_video_last    ( S_hdmi_last        ),
        .I_debug_status  ( S_hdmi_debug_status),
        .I_osd_en        ( 1'b1          ),      // ★ 红线1：OSD 恒开（基础要求④必须有安路 Logo）
        .I_mode_disp     ( S_mode_hdmi    ),      // lab_ex4: 模式数字 0..3（D4 域）
        .I_lat_ms        ( S_lat_ms       ),      // ★ P3：延迟值（毫秒）
        .I_lat_valid     ( S_lat_valid    ),      // ★ P3：延迟值有效
        .O_dis_frame_start( S_dis_frame_start ),  // ★ P3：显示帧起始脉冲
        // ★ P5：目标检测结果（已在上面跨域并寄存到 HDMI 域）
        .I_tgt_valid     ( S_tgt_valid_h  ),
        .I_tgt_x_min     ( S_tgt_x_min_h  ),
        .I_tgt_x_max     ( S_tgt_x_max_h  ),
        .I_tgt_y_min     ( S_tgt_y_min_h  ),
        .I_tgt_y_max     ( S_tgt_y_max_h  ),
        .I_tgt_tiles     ( S_tgt_tiles_h  ),
        .I_tgt_shape     ( S_tgt_shape_h  ),
        .I_tgt_x_d3      ( S_tgt_x_d3_h   ),
        .I_tgt_x_d2      ( S_tgt_x_d2_h   ),
        .I_tgt_x_d1      ( S_tgt_x_d1_h   ),
        .I_tgt_x_d0      ( S_tgt_x_d0_h   ),
        .I_tgt_y_d2      ( S_tgt_y_d2_h   ),
        .I_tgt_y_d1      ( S_tgt_y_d1_h   ),
        .I_tgt_y_d0      ( S_tgt_y_d0_h   ),
        .I_tgt_dbg_beat  ( S_tgt_dbg_beat_h),
        .I_tgt_dbg_warm  ( S_tgt_dbg_warm_h),
        .I_tgt_dbg_cb    ( S_tgt_dbg_cb_h  ),
        .I_tgt_dbg_cr    ( S_tgt_dbg_cr_h  ),
        // ★ P6：AE 状态诊断行（区域 (256,144)，见 hdmi_mixer.v 的 AEINFO_* 注释）
        .I_ae_en         ( S_ae_auto_h     ),   // 1=自动 0=手动（OSD 显示 A / M）
        .I_ae_val        ( S_ae_ae_h       ),   // 曝光（4 位十六进制）
        .I_ae_ag         ( S_ae_ag_h       ),   // 模拟增益（2 位十六进制）
        .I_ae_luma       ( S_ae_avg_h      ),   // 平均亮度（2 位十六进制）
        .I_ae_clip       ( S_ae_clip_h     ),   // 过曝像素数（5 位十六进制，用于看高光保护）
        .I_ae_sat        ( S_ae_sat_h      ),   // ★ 执行机构饱和指示（+ / - / 空格）
        // ★ P7：运动检测（运动框 + 计数行）
        .I_mot_x_min     ( S_mot_x_min_h   ),
        .I_mot_x_max     ( S_mot_x_max_h   ),
        .I_mot_y_min     ( S_mot_y_min_h   ),
        .I_mot_y_max     ( S_mot_y_max_h   ),
        .I_mot_blkcnt    ( S_mot_blkcnt_h  ),
        .I_mot_valid     ( S_mot_valid_h   ),
        .I_mot_global    ( S_mot_global_h  ),
        .O_video_rd_en   ( S_hdmi_window_rd_en),
        .I_video_rd_data ( S_video_rd_data    ),
        .O_hdmi_vsync    ( S_hdmi_out_vsync   ),
        .O_hdmi_hsync    ( S_hdmi_out_hsync   ),
        .O_hdmi_de       ( S_hdmi_out_de      ),
        .O_hdmi_data     ( S_hdmi_out_data    )
    );

    // ========================================================================
    // ★ P3：端到端处理延迟测量（高阶要求③）—— 2026-09-21 重写
    // ------------------------------------------------------------------------
    //  第一版把时间基准放在采集域，显示域总是取"最新标签"，结果屏上显示的是
    //  "当前采集帧内的相位"（0..采集帧周期之间来回扫），**不含帧缓冲那 2 帧**。
    //  上板实测即为 0~10 ms 扫动。详见 frame_latency.v 文件头的完整推导。
    //
    //  正确做法：按 **DDR BANK 号**索引标签。
    //      · 4 个 BANK；写指针 wp 每采集帧 +1，第 n 帧写入 BANK (n mod 4)；
    //      · 读指针 rp = wp + 2 (mod 4)，video_out 在每个显示帧起始
    //        把读地址切到 IMAGE_BASE_ADDR_{rp}；
    //      ⇒ 显示正在读的 BANK 就是 **2 个写入帧之前**那一帧。
    //        写 tag_ms[wp]、读 tag_ms[rp]，差值即真实延迟。
    //
    //  `wp`、`rp` 与两个帧起始脉冲**都在 ddr_clk**，故测量整体在该域完成
    //  （266.667 MHz），最后只把结果跨到 HDMI 像素域给 OSD。
    //  ⚠ rp = wp + 2 ⇒ 读写永不撞同一槽位；该槽位下次被写还在 2 个采集帧之后。
    // ========================================================================
    frame_latency #(
        // ⚠⚠ 这个频率**踩过一次坑，别再改错**：
        //    `S_ddr_clk` 这个名字极具误导性 —— 它**不是** 266.667 MHz 的 `ddr_clk`，
        //    而是 **66.667 MHz 的 `usr_clk`**（DDR2 用户接口时钟）。
        //    证据：TD 报告里 `u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk` 的 Fanout 只有 6，
        //    而 `video_in/video_out/mc_to_user_interface` 的寄存器都在 `usr_clk` 上。
        //    第一版我按名字写了 266666667 ⇒ 毫秒计数器慢 4 倍 ⇒
        //    **屏上延迟读数 = 真实值 ÷ 4**（上板表现为"一个十几毫秒的数"）。
        //    ⇒ 现由 tools/verify_td_reports.py §5c 自动交叉校验本参数与 TD 报告。
        .CLK_FREQ_HZ ( 66666667 ),   // = S_ddr_clk = u_ddr2/usr_clk（period 15.000 ns）
        .AVG_SHIFT   ( 8        ),    // EMA 2^8 = 256 帧 ≈ 4.2 s
        //   ⚠ 为什么档位选这么大：显示帧起始与采集帧起始是**异步**的，所以
        //     瞬时延迟本身就在 [2·P_c, 3·P_c) 内游走（一个采集帧周期的宽度），
        //     在板上表现为几秒一轮的缓慢扫描。τ≈256 帧 ≈ 4.2 s 能把这一轮
        //     基本平均掉，OSD 数字才稳定可读。设 0 即看原始瞬时值。
        .TAG_INIT    ( 32'd0    )     // 未就绪时输出 0（由 O_lat_valid=0 指示）
    ) u_frame_latency (
        // ---- 测量域（ddr_clk）----
        .I_clk               ( S_ddr_clk              ),
        .I_rst_n             ( S_rst_n                ),
        .I_wr_frame_start    ( S_video_in_frame_start ),
        .I_wr_bank           ( S_video_in_wp          ),
        .I_rd_frame_start    ( S_video_frame_start    ),
        .I_rd_bank           ( S_video_out_rp         ),
        // ---- OSD 域（hdmi_pixel_clk）----
        .I_clk_dis           ( S_hdmi_pixel_clk       ),
        .I_rst_dis_n         ( S_hdmi_rst_n           ),
        .O_latency_ms        ( S_lat_ms               ),
        .O_lat_valid         ( S_lat_valid            )
    );

    // ========================================================================
    // ★ P5：目标检测结果的跨域（S_csi_rx_clk → S_hdmi_pixel_clk）
    // ------------------------------------------------------------------------
    //  做法：**翻转标志 + 2 拍同步 + 边沿捕获**，而不是完整乒乓。
    //
    //  为什么这样是安全的（准静态多比特跨域）：
    //    · 数据每帧只变一次（在 isp_top 里由 tuser 锁存），一帧内**完全静止**
    //      （≈16.7 ms）；
    //    · 写侧在数据变化的**同一拍**翻转标志；读侧经 2 拍同步后才看到翻转，
    //      此时距数据变化已过 2~3 个 HDMI 周期（≈40 ns），而数据还要再静止
    //      ≈16.6 ms ⇒ **捕获瞬间绝不会撞上数据跳变**。
    //    · 唯一的边角是"捕获正好发生在数据变化那一拍"，这需要同步链延迟为 0，
    //      由 2 拍同步保证不会发生。
    //
    //  ⚠ 若将来这些量变成"每拍都变"，必须改成乒乓结构（参考 frame_latency.v）。
    // ========================================================================
    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if (!S_rst_n) S_tgt_tgl <= 1'b0;
        else if (S_tgt_frame) S_tgt_tgl <= ~S_tgt_tgl;
    end

    always @(posedge S_hdmi_pixel_clk or negedge S_hdmi_rst_n) begin
        if (!S_hdmi_rst_n) begin
            S_tgt_t1 <= 1'b0; S_tgt_t2 <= 1'b0; S_tgt_t3 <= 1'b0;
            S_tgt_valid_h <= 1'b0;
            S_tgt_x_min_h <= 11'd0; S_tgt_x_max_h <= 11'd0;
            S_tgt_y_min_h <= 10'd0; S_tgt_y_max_h <= 10'd0;
            S_tgt_tiles_h <= 8'd0;  S_tgt_shape_h   <= 2'd0;
            S_tgt_x_d3_h <= 4'd0; S_tgt_x_d2_h <= 4'd0;
            S_tgt_x_d1_h <= 4'd0; S_tgt_x_d0_h <= 4'd0;
            S_tgt_y_d2_h <= 4'd0; S_tgt_y_d1_h <= 4'd0; S_tgt_y_d0_h <= 4'd0;
            S_tgt_dbg_beat_h <= 8'd0; S_tgt_dbg_warm_h <= 20'd0;
            S_tgt_dbg_cb_h <= 8'd0;  S_tgt_dbg_cr_h <= 8'd0;
        end else begin
            S_tgt_t1 <= S_tgt_tgl;
            S_tgt_t2 <= S_tgt_t1;
            S_tgt_t3 <= S_tgt_t2;
            if (S_tgt_t2 ^ S_tgt_t3) begin      // 有新结果 ⇒ 一次性捕获整组
                S_tgt_valid_h <= S_tgt_valid;
                S_tgt_x_min_h <= S_tgt_x_min; S_tgt_x_max_h <= S_tgt_x_max;
                S_tgt_y_min_h <= S_tgt_y_min; S_tgt_y_max_h <= S_tgt_y_max;
                S_tgt_tiles_h <= S_tgt_tiles; S_tgt_shape_h   <= S_tgt_shape;
                S_tgt_x_d3_h <= S_tgt_x_d3; S_tgt_x_d2_h <= S_tgt_x_d2;
                S_tgt_x_d1_h <= S_tgt_x_d1; S_tgt_x_d0_h <= S_tgt_x_d0;
                S_tgt_y_d2_h <= S_tgt_y_d2; S_tgt_y_d1_h <= S_tgt_y_d1;
                S_tgt_y_d0_h <= S_tgt_y_d0;
                S_tgt_dbg_beat_h <= S_tgt_dbg_beat;
                S_tgt_dbg_warm_h <= S_tgt_dbg_warm;
                S_tgt_dbg_cb_h   <= S_tgt_dbg_cb;
                S_tgt_dbg_cr_h   <= S_tgt_dbg_cr;
            end
        end
    end

    // ========================================================================
    // ★ P7：运动检测结果的跨域（S_csi_rx_clk → S_hdmi_pixel_clk）
    //   做法与 P5 的目标框**逐字同一套**：翻转标志 + 2 拍同步 + 边沿捕获。
    //   安全性论证也相同：数据每帧只变一次（一帧内完全静止 ≈16.7 ms），
    //   写侧在数据变化同一拍翻标志，读侧 2 拍（≈40 ns）后才看到 ⇒ 捕获瞬间
    //   绝不会撞上跳变。⚠ 若将来这些量变成"每拍都变"，必须改乒乓。
    // ========================================================================
    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if (!S_rst_n) S_mot_tgl <= 1'b0;
        else if (S_mot_frame) S_mot_tgl <= ~S_mot_tgl;
    end

    always @(posedge S_hdmi_pixel_clk or negedge S_hdmi_rst_n) begin
        if (!S_hdmi_rst_n) begin
            S_mot_t1 <= 1'b0; S_mot_t2 <= 1'b0; S_mot_t3 <= 1'b0;
            S_mot_x_min_h <= 11'd0; S_mot_x_max_h <= 11'd0;
            S_mot_y_min_h <= 10'd0; S_mot_y_max_h <= 10'd0;
            S_mot_blkcnt_h <= 14'd0;
            S_mot_valid_h <= 1'b0; S_mot_global_h <= 1'b0;
        end else begin
            S_mot_t1 <= S_mot_tgl;
            S_mot_t2 <= S_mot_t1;
            S_mot_t3 <= S_mot_t2;
            if (S_mot_t2 ^ S_mot_t3) begin      // 有新结果 ⇒ 一次性捕获整组
                S_mot_x_min_h <= S_mot_x_min; S_mot_x_max_h <= S_mot_x_max;
                S_mot_y_min_h <= S_mot_y_min; S_mot_y_max_h <= S_mot_y_max;
                S_mot_blkcnt_h <= S_mot_blkcnt;
                S_mot_valid_h <= S_mot_valid;
                S_mot_global_h <= S_mot_global;
            end
        end
    end

    // ========================================================================
    // ★ P6：AE 状态（AE / AG / 平均亮度 / 自动手动）的跨域
    //        S_24m_clk → S_hdmi_pixel_clk，同样用"翻转标志 + 2 拍同步 + 边沿捕获"
    // ------------------------------------------------------------------------
    //  为什么这里必须是"变化即翻标志"而不是"每帧翻"：
    //    AE 值的变化时机由闭环决定（**每 2 帧才可能动一次**，见 ae_ctrl.THROTTLE），
    //    与任何视频帧边界都不同步。若用视频帧边界定时捕获，有可能正好撞上
    //    ae_set 在那一拍改值 ⇒ 采到新旧混合的多比特组合。
    //    ⇒ 改用"写侧一变就翻标志"：读侧 2 拍同步后才看到翻转（≈40 ns 后），
    //      而数据是**寄存器输出且之后至少静止 2 帧（≈33 ms）**
    //      ⇒ 捕获瞬间绝不可能撞上跳变。这与 P5 是同一套论证，只是触发源不同。
    //  ⚠ 前提：这些量每拍都变就失效 —— 它们是 24 MHz 域寄存器，最快也是
    //     2 帧一次（33 ms），远慢于 HDMI 域 13.3 ns 的周期。
    // ========================================================================
    // ⚠ 这些 reg 的**声明**已上移到文件顶部的"P6 声明区"（必须早于
    //   `u_hdmi_mixer` 例化处的使用，否则 TD/ModelSim 会先按 1 位隐式线网使用，
    //   报 `HDL-7225 'S_ae_ae_h' is already implicitly declared`，屏上显示就是错的）。
    always @(posedge S_24m_clk or negedge S_rst_n) begin
        if (!S_rst_n) begin
            S_ae_osd_tgl  <= 1'b0;
            S_ae_osd_ae_d <= 16'd0;
            S_ae_osd_ag_d <= 16'd0;
        end else begin
            S_ae_osd_ae_d <= S_ae;
            S_ae_osd_ag_d <= S_ag;
            if ((S_ae != S_ae_osd_ae_d) || (S_ag != S_ae_osd_ag_d) || S_auto_tog
                || (S_ae_sat != S_ae_osd_sat_d))
                S_ae_osd_tgl <= ~S_ae_osd_tgl;
            S_ae_osd_sat_d <= S_ae_sat;
        end
    end

    // ⚠ 这一节的 reg 声明**已全部上移**到文件顶部的"P6 声明区"
    //   （必须早于 `u_hdmi_mixer` 例化处的使用，否则会被当成 1 位隐式线网）。
    always @(posedge S_hdmi_pixel_clk or negedge S_hdmi_rst_n) begin
        if (!S_hdmi_rst_n) begin
            S_ae_t1 <= 1'b0; S_ae_t2 <= 1'b0; S_ae_t3 <= 1'b0;
            S_ae_ae_h <= 16'd0; S_ae_ag_h <= 16'd0;
            S_ae_avg_h <= 8'd0; S_ae_clip_h <= 20'd0;
            S_ae_auto_h <= 1'b1;
        end else begin
            S_ae_t1 <= S_ae_osd_tgl;
            S_ae_t2 <= S_ae_t1;
            S_ae_t3 <= S_ae_t2;
            if (S_ae_t2 ^ S_ae_t3) begin      // AE 状态有更新 ⇒ 一次性捕获整组
                S_ae_ae_h   <= S_ae;
                S_ae_ag_h   <= S_ag;
                S_ae_avg_h  <= S_ae_avg_24;
                S_ae_clip_h <= S_ae_clip_24;
                S_ae_auto_h <= S_ae_auto;
                S_ae_sat_h  <= S_ae_sat;      // ★ 饱和指示（OSD 首行第 2 槽 +/-）
            end
        end
    end

    hdmi_tx u_hdmi_tx(
        .I_pixel_clk        ( S_hdmi_pixel_clk  ),
        .I_serial_clk       ( S_hdmi_serial_clk ),
        .I_rst              ( ~S_hdmi_rst_n     ),
        .I_key_in           ( 1'b0              ),
        .I_edid_read_trig   ( 1'b0              ),
        .O_edid_read_valid  (                   ),
        .O_edid_read_data   (                   ),
        .I_video_rgb_enable ( 1'b1              ),
        .I_video_in_vs      ( S_hdmi_out_vsync  ),
        .I_video_in_de      ( S_hdmi_out_de     ),
        .I_video_in_user    ( 1'b0              ),
        .I_video_in_valid   ( 1'b0              ),
        .I_video_in_last    ( 1'b0              ),
        .O_video_in_ready   (                   ),
        .I_video_in_data    ( S_hdmi_out_data   ),
        .I_audio_valid      ( 1'b0              ),
        .I_audio_left_data  ( 24'd0             ),
        .I_audio_right_data ( 24'd0             ),
        .I_i2s_BCLK         ( 1'b0              ),
        .I_i2s_LRCK         ( 1'b0              ),
        .I_i2s_DOUT         ( 1'b0              ),
        .O_ddc_scl          (                   ),
        .O_hdmi_clk_p       (                   ),
        .O_hdmi_tx_p        (                   ),
        .O_tmds_ch0_p       ( O_tmds_ch0_p      ),
        .O_tmds_ch1_p       ( O_tmds_ch1_p      ),
        .O_tmds_ch2_p       ( O_tmds_ch2_p      ),
        .O_tmds_clk_p       ( O_tmds_clk_p      )
    );


    
endmodule
