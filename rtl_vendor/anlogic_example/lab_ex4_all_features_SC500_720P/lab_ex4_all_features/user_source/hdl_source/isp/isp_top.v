// ============================================================================
//  isp_top.v  --  lab_ex4_all_features 版本
// ----------------------------------------------------------------------------
//  【2026-09-20 红线1 改造】Sobel 边缘检测 → 灰度/二值化/反色
//  ---------------------------------------------------------------
//  赛题 2.3 基础要求②：「提交的参赛作品中图像处理算法不能和参考实例相同」，
//  而官方参考 lab_ex_2 就是**边缘检测**。原实现把 Sobel（`edge_detect_96`）
//  放在数据通路上，属于不合规，故本次改造：
//
//    * 移除 `edge_detect_96`（连同端口 `I_edge_en`）
//    * 接入 `gray_binary_96`：mode=0 原图直通 / 1 灰度 / 2 二值化 / 3 反色
//    * 端口改为 `I_img_mode[1:0]` + `I_img_threshold[7:0]`
//    * 数据通路**固定**走 gray_binary_96 —— 因为它的 mode=0 本身就是原图直通，
//      四选一完全在模块内部完成，不需要外部 mux，也就不存在
//      "切换瞬间两路延迟不一致"的错位风险
//
//  改动依据：doc/analysis/复盘-撕裂事故与全部方案回归-2026-09-20.md §2.5 红线1
//
//  与 lab1 版的区别：新增 `I_img_mode` / `I_img_threshold` 端口。
//
//  重要约束（务必遵守，否则会引入难查的问题）
//  ---------------------------------------------------------------
//  1) **tready 链保持与 lab2 逐字符一致**（仅把 edge 换成 gb）：
//         assign awb_O_tready = gb_O_tready;
//         assign gb_O_tready  = O_tready;
//     顶层 `O_tready` 是既有遗留（声明为 input、接一根无驱动 wire），
//     `I_tready` 悬空。**刻意不改**（见 risks.md R-02 / B-02）。
//
//  2) **四条信号必须同源**，禁止逐位混选：
//         tdata / tvalid / tlast / tuser 必须来自同一个源，
//     否则 data_96bit_to_128bit 会拿到"数据属于 A、valid 属于 B"的错配。
//
//  3) **算法模块始终接收数据**（不做输入侧旁路）：
//     这样模式切换时下游窗口内容始终连续，不会出现残留/撕裂。
//     `gray_binary_96` 是**纯逐像素**处理（无行缓冲，只占 1 拍），
//     所以"始终运行"的代价极小，也不影响 awb 的吞吐。
//
//  4) 保留 lab1 原有的端口方向写法（`input O_tready` / `output I_tready`
//     命名与方向相反）——这是既有遗留，改了会牵动顶层连接。
// ============================================================================
module isp_top (
    input 			axi4s_video_aclk,
    input 			I_rst_n			,
    input 			I_tlast			,
    input 			I_tuser			,
    input [39:0] 	I_tdata			,
    input 			I_tvalid		,
    input [9:0] 	I_tdest			,
    input [2:0] 	I_img_mode		,   // ★ P4：0=原图 1=灰度 2=二值化 3=反色 4=卡通
    input [7:0] 	I_img_threshold	,   // 二值化阈值
    input [7:0] 	I_cartoon_th	,   // ★ P4：卡通形态学梯度阈值
    // ---- ★ P5：颜色目标检测每帧标量结果（扩展② + 进阶②）----
    //   ⚠ 这些是**帧率信号**（每帧才变一次），送进 HDMI 域做 OSD 前必须先落寄存器，
    //     绝不能让它们直接参与显示域的组合逻辑（P3 踩过这个坑，见 P3 报告 §2.7）。
    output [10:0] 	O_tgt_x_min		,
    output [10:0] 	O_tgt_x_max		,
    output [9:0]  	O_tgt_y_min		,
    output [9:0]  	O_tgt_y_max		,
    output [7:0]  	O_tgt_tiles		,
    output [1:0]  	O_tgt_shape		,
    output        	O_tgt_valid		,
    output        	O_tgt_frame		,   // 帧结算单拍脉冲（跨域握手用）
    // 十进制位：**在 ISP 域算好**再跨域（HDMI 域只做"槽位→字符码"查表）
    output [3:0]  	O_tgt_x_d3		,   // X 千
    output [3:0]  	O_tgt_x_d2		,   // X 百
    output [3:0]  	O_tgt_x_d1		,   // X 十
    output [3:0]  	O_tgt_x_d0		,   // X 个
    output [3:0]  	O_tgt_y_d2		,   // Y 百
    output [3:0]  	O_tgt_y_d1		,   // Y 十
    output [3:0]  	O_tgt_y_d0		,   // Y 个
    // ★★ 临时诊断（上板定位用；定位完连同 OSD 那一行一起删）
    output [7:0]  	O_tgt_dbg_beat	,
    output [19:0] 	O_tgt_dbg_warm	,
    output [7:0]  	O_tgt_dbg_cb	,
    output [7:0]  	O_tgt_dbg_cr	,
    // ---- ★ P6：每帧亮度统计（AE 闭环的"眼睛"）----
    //   与 P5 同理：这是**帧率信号**，跨到 24 MHz 的 ae_ctrl 时用
    //   "准静态多比特 + 翻转标志"（luma_stats 里已锁存，本层只做连线）。
    //   ⚠ **平均亮度不在这里输出**：它在 ae_ctrl（24 MHz 域）里算 ——
    //     放在本域会变成 ISP 域的最差路径（实测 Fmax 77.954 → 60.361 MHz）。
    output [31:0] 	O_ae_sum		,   // 本帧 ΣY
    output [19:0] 	O_ae_clip		,   // 本帧 Y>=250 的像素数
    output        	O_ae_tog		,   // ★ 跨域握手：每帧翻转
    // ---- ★ P7：运动目标检测每帧标量（进阶要求④）----
    output [10:0] 	O_mot_x_min		,
    output [10:0] 	O_mot_x_max		,
    output [9:0]  	O_mot_y_min		,
    output [9:0]  	O_mot_y_max		,
    output [13:0] 	O_mot_blkcnt	,
    output        	O_mot_valid		,
    output        	O_mot_global	,
    output        	O_mot_frame		,
    input 			O_tready		,
    output [127:0] 	O_tdata			,
    output 			O_tlast			,
    output 			O_tuser			,
    output 			O_tvalid		,
    output 			I_tready
);

  wire         m_aixs_tvalid;  //synthesis keep
  wire [127:0] m_aixs_tdata;   //synthesis keep
  wire         m_aixs_tuser;   //synthesis keep
  wire         m_aixs_tlast;   //synthesis keep
  wire         m_aixs_tready;  //synthesis keep

  wire [ 95:0] m_aixs_tdata_96;  //synthesis keep

  wire         awb_O_tlast;    //synthesis keep
  wire         awb_O_tuser;    //synthesis keep
  wire [ 95:0] awb_O_tdata;    //synthesis keep
  wire         awb_O_tvalid;   //synthesis keep
  wire         awb_O_tready;   //synthesis keep

  // ---- ★ 红线1：gray_binary_96（灰度/二值化/反色）的输出 ----
  wire         gb_O_tlast;     //synthesis keep
  wire         gb_O_tuser;     //synthesis keep
  wire [ 95:0] gb_O_tdata;     //synthesis keep
  wire         gb_O_tvalid;    //synthesis keep
  wire         gb_O_tready;    //synthesis keep

  // ---- ★ P4：cartoon_96（卡通化）的输出 ----
  wire         ct_O_tlast;     //synthesis keep
  wire         ct_O_tuser;     //synthesis keep
  wire [ 95:0] ct_O_tdata;     //synthesis keep
  wire         ct_O_tvalid;    //synthesis keep
  wire         ct_O_tready;    //synthesis keep

  // ---- 新增：送入 data_96bit_to_128bit 的整体选中结果 ----
  wire         sel_O_tlast;
  wire         sel_O_tuser;
  wire [ 95:0] sel_O_tdata;
  wire         sel_O_tvalid;

  wire         awb_O_tuser_128;  //synthesis keep
  wire         awb_O_tvalid_128; //synthesis keep
  wire [127:0] awb_O_tdata_128;  //synthesis keep

  // ---------------------------------------------------------------------------
  // tready 链：与 lab2 逐字符一致，保持原样
  // ---------------------------------------------------------------------------
  assign awb_O_tready  = gb_O_tready;
  assign gb_O_tready   = ct_O_tready;      // ★ P4：tready 链再串一级
  assign ct_O_tready   = O_tready;

  assign O_tdata  = awb_O_tdata_128;
  assign O_tlast  = awb_O_tlast    ;
  assign O_tuser  = awb_O_tuser_128    ;
  assign O_tvalid = awb_O_tvalid_128   ;

  //assign m_aixs_tready = O_tready;
  //assign O_tdata  = m_aixs_tdata;
  //assign O_tlast  = m_aixs_tlast    ;
  //assign O_tuser  = m_aixs_tuser    ;
  //assign O_tvalid = m_aixs_tvalid   ;

  // ==========================================================================
  // ★ P4 改造：数据通路 mux（模式 0..4）
  // --------------------------------------------------------------------------
  //   两个算法模块**并行常开**（都吃 awb 的输出），各自处理，最后由 mux 二选一：
  //     gray_binary_96 : mode 0 原图 / 1 灰度 / 2 二值化 / 3 反色（纯逐像素，1 拍）
  //     cartoon_96     : 卡通化（量化 + 形态学梯度描边；有行缓冲，约 2 行延迟）
  //
  //   ⚠ 为什么不做"按模式停喂数据"的输入侧旁路：
  //     与 edge_detect_96 同理 —— 行缓冲若在旁路期停喂，解除旁路瞬间窗口内容
  //     与当前像素不对应，画面会残留/撕裂。两个模块都**全时运行**，
  //     代价是卡通模块持续消耗功耗，收益是切换干净、无残留。
  //
  //   ⚠ 两条通路的**延迟不同**（gb 约 1 拍，ct 约 2 行）。切换模式时，
  //     下游 data_96bit_to_128bit 会经历一次短暂的时序错接，
  //     表现为切换后**首帧的边缘若干行**可能有错位 —— 可接受（一帧内自愈）。
  // ==========================================================================
  assign sel_O_tdata  = (I_img_mode == 3'd4) ? ct_O_tdata  : gb_O_tdata ;
  assign sel_O_tvalid = (I_img_mode == 3'd4) ? ct_O_tvalid : gb_O_tvalid;
  assign sel_O_tlast  = (I_img_mode == 3'd4) ? ct_O_tlast  : gb_O_tlast ;
  assign sel_O_tuser  = (I_img_mode == 3'd4) ? ct_O_tuser  : gb_O_tuser ;


demosaic #(
    .IMG_HEIGHT          (720 ), // 图像高度
    .IMG_WIDTH           (1280), // 图像宽度
    .data_complete_delay (50  ),
    .BAYER_MODE          ("BGGR")
)
u_demosaic
(
    .I_clk   			(axi4s_video_aclk)	,   // 时钟信号
    .I_rst_n 			(I_rst_n)	,   // 复位信号，低有效
    .axi4s_video_tdata 	(I_tdata)	,  // AXI4-Stream视频数据
    .axi4s_video_tdest 	(I_tdest)	,
    .axi4s_video_tlast 	(I_tlast)	,  // 行结束信号
    .axi4s_video_tvalid	(I_tvalid)	,  // 数据有效信号
    .axi4s_video_tuser 	(I_tuser)	,  // 帧开始信号
    .axi4s_video_tready	(I_tready)	,  // 从模块准备好接受数据
    .O_tlast  			(m_aixs_tlast)	,  // 输出行结束信号
    .O_tuser  			(m_aixs_tuser)	,  // 输出帧开始信号
    .O_tdata  			(m_aixs_tdata)	,  // 输出数据
    .O_tvalid 			(m_aixs_tvalid)	,  // 输出数据有效信号
    .O_tready   		(m_aixs_tready)	   // 输出数据准备好信号
);

data128_96 u_data128_96 (
    .I_tdata(m_aixs_tdata),
    .O_tdata(m_aixs_tdata_96)
);

awb #(
    .IMG_HEIGHT(720 ),
    .IMG_WIDTH (1280)
) u_awb (
    .I_clk   (axi4s_video_aclk),
    .I_rst_n (I_rst_n),
    .I_tlast (m_aixs_tlast),
    .I_tuser (m_aixs_tuser),
    .I_tdata (m_aixs_tdata_96),
    .I_tvalid(m_aixs_tvalid),
    .I_tready(m_aixs_tready),
    .O_tlast (awb_O_tlast ),
    .O_tuser (awb_O_tuser ),
    .O_tdata (awb_O_tdata ),
    .O_tvalid(awb_O_tvalid),
    .O_tready(awb_O_tready)
);

// ---------------------------------------------------------------------------
// ★ 红线1 改造：灰度/二值化/反色（取代原 Sobel 边缘检测）
//    输入接 awb 输出；mode[1:0] 由按键经 D1→D2 同步后驱动。
//    接口与 edge_detect_96 完全兼容（像素拆解 pix0=[95:72]…pix3=[23:0] 一致），
//    且**不含行缓冲**（纯逐像素，IP 域只占 1 拍），不会影响 awb 的吞吐。
// ---------------------------------------------------------------------------
gray_binary_96 #(
    .IMG_WIDTH (1280),
    .IMG_HEIGHT(720 )
) u_gray_binary_96 (
    .I_clk       (axi4s_video_aclk),
    .I_rst_n     (I_rst_n),
    .I_tlast     (awb_O_tlast),
    .I_tuser     (awb_O_tuser),
    .I_tdata     (awb_O_tdata),
    .I_tvalid    (awb_O_tvalid),
    .I_tready    (awb_O_tready),
    .I_mode      (I_img_mode),
    .I_threshold (I_img_threshold),
    .O_tlast     (gb_O_tlast),
    .O_tuser     (gb_O_tuser),
    .O_tdata     (gb_O_tdata),
    .O_tvalid    (gb_O_tvalid),
    .O_tready    (gb_O_tready)
);

// ---------------------------------------------------------------------------
// ★ P4 新增：卡通化（颜色量化 + 形态学梯度描边）—— 扩展要求①
//    输出接 mux 的 mode=4 侧。见模块头注释了解 3x3 窗口的实现方式。
// ---------------------------------------------------------------------------
cartoon_96 #(
    .IMG_WIDTH (1280),
    .IMG_HEIGHT(720),
    .GRAD_TH   (8'd20)
) u_cartoon_96 (
    .I_clk      (axi4s_video_aclk),
    .I_rst_n    (I_rst_n),
    .I_tlast    (awb_O_tlast),
    .I_tuser    (awb_O_tuser),
    .I_tdata    (awb_O_tdata),
    .I_tvalid   (awb_O_tvalid),
    .I_tready   (awb_O_tready),
    .I_grad_th  (I_cartoon_th),
    .O_tlast    (ct_O_tlast),
    .O_tuser    (ct_O_tuser),
    .O_tdata    (ct_O_tdata),
    .O_tvalid   (ct_O_tvalid),
    .O_tready   (ct_O_tready)
);

// ---------------------------------------------------------------------------
// ★ P5 新增：颜色目标检测 + 包围框（扩展要求② + 高阶要求②）
//    **纯旁观者**：与 gray_binary_96 / cartoon_96 并联，同样接 awb 的输出
//    （必须接 awb，不能接 mux 输出 —— 灰度/二值/反色/卡通模式会破坏颜色信息）。
//    它**不产生任何反压**，也不参与 tready 链，故 `I_tready` 接 1'b1。
//    检测精度靠 tile 投影统计（16×9 个 80×80 tile），不做连通域标记。
//    详见 target_detect_96.v 头注释（含"为什么放 ISP 域"的实测依据）。
// ---------------------------------------------------------------------------
target_detect_96 #(
    .IMG_WIDTH (1280),
    .IMG_HEIGHT(720 )
) u_target_detect_96 (
    .I_clk        (axi4s_video_aclk),
    .I_rst_n      (I_rst_n),
    .I_tlast      (awb_O_tlast),
    .I_tuser      (awb_O_tuser),
    .I_tdata      (awb_O_tdata),
    .I_tvalid     (awb_O_tvalid),
    .I_tready     (1'b1),                  // 旁观者：无反压
    .O_x_min      (O_tgt_x_min),
    .O_x_max      (O_tgt_x_max),
    .O_y_min      (O_tgt_y_min),
    .O_y_max      (O_tgt_y_max),
    .O_tile_cnt   (O_tgt_tiles),
    .O_shape      (O_tgt_shape),
    .O_valid      (O_tgt_valid),
    .O_frame_start(O_tgt_frame),
    .O_x_min_d3   (O_tgt_x_d3),
    .O_x_min_d2   (O_tgt_x_d2),
    .O_x_min_d1   (O_tgt_x_d1),
    .O_x_min_d0   (O_tgt_x_d0),
    .O_y_min_d2   (O_tgt_y_d2),
    .O_y_min_d1   (O_tgt_y_d1),
    .O_y_min_d0   (O_tgt_y_d0),
    .O_dbg_beat_k (O_tgt_dbg_beat),
    .O_dbg_warm   (O_tgt_dbg_warm),
    .O_dbg_cb     (O_tgt_dbg_cb),
    .O_dbg_cr     (O_tgt_dbg_cr)
);

// ---------------------------------------------------------------------------
// ★ P6 新增：每帧亮度统计（AE 闭环的"眼睛"）
//    与 target_detect_96 完全同一套约定：
//      · **纯旁观者**：接 awb 输出（不是 mux 输出 —— 灰度/二值/卡通会破坏颜色），
//        不产生反压、不参与 tready 链；
//      · 与 target_detect_96 并联，两者互不影响；
//      · **帧边界靠拍数自计时**，不用 awb 的 tuser/tlast（铁律四）；
//      · 零除法、零 `*`（铁律三）。
//    详见 luma_stats.v 头注释。
// ---------------------------------------------------------------------------
luma_stats #(
    .IMG_WIDTH (1280),
    .IMG_HEIGHT(720 )
) u_luma_stats (
    .I_clk        (axi4s_video_aclk),
    .I_rst_n      (I_rst_n),
    .I_tdata      (awb_O_tdata),
    .I_tvalid     (awb_O_tvalid),
    .O_sum        (O_ae_sum),
    .O_clip       (O_ae_clip),
    .O_dark       (),
    .O_frame_done (),
    .O_tog        (O_ae_tog)
);

// ---------------------------------------------------------------------------
// ★ P7 新增：运动目标检测（进阶要求④）
//    与 target_detect_96 / luma_stats **完全同一套约定**：
//      · **纯旁观者**：接 awb 输出（不是 mux 输出），不产生反压、不参与 tready 链；
//      · 三个旁观者并联、互不影响；
//      · 帧边界靠拍数自计时 + `I_tuser` 相位对齐（铁律四 + P5 §11 的教训）；
//      · 亮度代理用 **G 通道**（差分运算只需单调一致，省掉 77/150/29 的移位加法）。
//    详见 motion_detect.v 头注释与 doc/analysis/P7设计-运动目标检测.md。
// ---------------------------------------------------------------------------
motion_detect #(
    .IMG_WIDTH (1280),
    .IMG_HEIGHT(720 )
) u_motion_detect (
    .I_clk        (axi4s_video_aclk),
    .I_rst_n      (I_rst_n),
    .I_tuser      (awb_O_tuser),        // 仅用于帧相位对齐（与 target_detect_96 同一套论证）
    .I_tdata      (awb_O_tdata),
    .I_tvalid     (awb_O_tvalid),
    .O_x_min      (O_mot_x_min),
    .O_x_max      (O_mot_x_max),
    .O_y_min      (O_mot_y_min),
    .O_y_max      (O_mot_y_max),
    .O_blk_cnt    (O_mot_blkcnt),
    .O_valid      (O_mot_valid),
    .O_global_chg (O_mot_global),
    .O_frame_start(O_mot_frame),
    .O_motion_raw ()
);

    data_96bit_to_128bit u_data_96bit_to_128bit(        .I_clk              ( axi4s_video_aclk  ),
        .I_rst_n            ( I_rst_n           ),

        .I_96b_frame_start  ( sel_O_tuser	    ),   // ★ 由 awb_O_tuser 改为 mux 输出
        .I_96b_valid        ( sel_O_tvalid 		),   // ★ 由 awb_O_tvalid 改为 mux 输出
        .I_96b_data         ( sel_O_tdata		),   // ★ 由 awb_O_tdata 改为 mux 输出

        .O_128b_frame_start ( awb_O_tuser_128  	),
        .O_128b_valid       ( awb_O_tvalid_128 	),
        .O_128b_data        ( awb_O_tdata_128  	)
    );



//data96_128 u_data96_128 (
//    .I_tdata(awb_O_tdata),
//    .O_tdata(awb_O_tdata_128)
//);

endmodule
