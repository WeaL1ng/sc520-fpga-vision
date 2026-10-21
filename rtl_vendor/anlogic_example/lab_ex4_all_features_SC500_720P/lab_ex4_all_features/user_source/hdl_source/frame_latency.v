// ============================================================================
//  frame_latency.v  --  端到端处理延迟测量（P3 高阶要求③）★ 2026-09-21 重写
//
//  目的：测量"摄像头采集某一帧" → "该帧显示在 HDMI 上"之间的延迟（毫秒），
//        供 OSD 显示 "LATENCY: xx ms"。
//
//  ===========================================================================
//  ★★ 为什么整个重写：第一版在**集成层**是错的（上板才发现）
//  ===========================================================================
//  第一版（2026-09-21 上午上板的那版）是：
//      · 时间基准在**采集域**（MIPI 字节时钟），每帧起始写一个 {ms, 帧号} 标签；
//      · 显示域**总是取走最新标签**，再和"显示帧号"比大小当有效门控。
//
//  上板实测：屏上数字在 **0 到约 10 ms 之间来回扫**。
//
//  推导一下就明白它算的是什么：设采集帧 n 的起始时刻为 C_n，显示帧起始为 D_j，
//  `S_held_ms` 恒等于**最近一次**采集帧起始的时间戳 C_m。于是
//        O_latency_ms = S_ms_cnt − S_held_ms = D_j − C_m ∈ [0, P_c)
//  即"**当前采集帧内已经走了多久**"（相位），根本不含帧缓冲那 2 帧的延迟！
//  它的模就是采集帧周期 P_c（板子上看到的上限 ≈10 ms ⇒ 采集约 100 fps）。
//  又因为采集与显示是两个独立时钟，这个相位缓慢漂移 ⇒ 看起来就是在扫。
//
//  另外"显示帧号 ≥ 标签帧号"这个门控也是错的：`S_cap_frame_no`（采集帧数）
//  与 `S_dis_frame_no`（显示帧数）**起点不同**（HDMI 先起来、MIPI 后锁），
//  两个计数的固定偏移未知，拿它们比大小没有意义。
//
//  ===========================================================================
//  ★★★ 正确做法：按 **DDR BANK 号**索引标签（这才是"哪一帧"的唯一共同索引）
//  ===========================================================================
//  数据通路实测（video_in.v / video_out.v）：
//      · 帧缓冲 = 4 个 BANK，写指针 `wp`（2 位）每**采集**帧 +1；
//        第 n 帧写入 BANK (n mod 4)；
//      · 读指针 `rp`（2 位）在每次采集帧起始被置为 **wp + 2 (mod 4)**；
//      · video_out 在每个**显示**帧起始把读地址切到 IMAGE_BASE_ADDR_{rp}。
//    ⇒ 显示正在读的 BANK，正是 **2 个写入帧之前**那一帧 ⇒ 结构延迟 = 2 个采集帧。
//
//  所以：把时间戳写进 `tag_ms[wp]`，显示时读 `tag_ms[rp]`，差值就是真实延迟。
//    · rp = wp + 2 ⇒ 两者**永远不是同一个 BANK**，同一槽位不会读写冲突；
//    · 该 BANK 上一次被写是 2 个采集帧之前，下一次是 2 个采集帧之后 ⇒ 余量充足。
//
//  这个做法**不依赖采集/显示的帧率关系**，也不依赖任何"固定偏移"假设。
//
//  ===========================================================================
//  ★ 时钟域
//  ===========================================================================
//  `wp`、`rp`、以及 video_in/video_out 里的两个帧起始脉冲**都在 `ddr_clk`**，
//  所以测量整体放在 ddr_clk 域做（266.667 MHz），只在最后把结果跨到
//  HDMI 像素域给 OSD 用（乒乓 + 翻转标志，与本文件旧版相同的手法）。
//
//  ★ 关于"数值会在一个采集帧周期内游走"
//    `D_j − C_{k-2} ∈ [2·P_c, 3·P_c)` —— 也就是说"延迟"本身取决于你看的是
//    该帧的哪个像素（帧首 vs 帧尾）。这是帧缓冲型流水线的固有性质，不是 bug。
//    为了 OSD 上数字可读，这里做了**指数滑动平均**（`AVG_SHIFT`，默认 2^6=64 帧
//    ≈1 秒）。把 `AVG_SHIFT` 设为 0 即直通未平滑的瞬时值。
// ============================================================================
`timescale 1ns/1ps

module frame_latency #(
    parameter integer CLK_FREQ_HZ  = 266666667,  // 测量域时钟（ddr_clk 实测 266.667 MHz）
    parameter integer MS_DIV       = 0,          // 0 = 自动用 CLK_FREQ_HZ/1000
    parameter integer AVG_SHIFT    = 6,          // EMA 平滑档位；0 = 不平滑（直通）
    parameter integer MAX_VALID_MS = 500,        // 差值上限，超过判为无效（挡启动瞬态）
    parameter integer TAG_INIT     = 0           // 未就绪时输出的占位值
)(
    // ---- 测量域（= ddr_clk）：两个帧事件 + 两个 BANK 号 ----
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_wr_frame_start,   // 采集帧写入起始（video_in.S_frame_start）
    input  wire [1:0]  I_wr_bank,          // 本帧要写入的 BANK（video_in.S_video_in_wp）
    input  wire        I_rd_frame_start,   // 显示帧起始（video_out.S_video_frame_start）
    input  wire [1:0]  I_rd_bank,          // 正在读的 BANK（video_in.O_video_out_rp）

    // ---- OSD 域（hdmi_pixel_clk）----
    input  wire        I_clk_dis,
    input  wire        I_rst_dis_n,

    output reg  [31:0] O_latency_ms,
    output reg         O_lat_valid
);

    localparam [23:0] DIV = (MS_DIV > 0) ? MS_DIV[23:0] : (CLK_FREQ_HZ / 1000);

    // ========================================================================
    // 1. 测量域：毫秒计数 + 4 个 BANK 的标签
    // ========================================================================
    reg [23:0] S_div_cnt;
    reg [31:0] S_ms;

    reg [31:0] S_tag_ms [0:3];      // 每个 BANK 最近一次"采集帧写入起始"的时间戳
    reg  [3:0] S_tag_seen;          // 该 BANK 是否至少写过一次

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_div_cnt   <= 24'd0;
            S_ms        <= 32'd0;
            S_tag_ms[0] <= 32'd0;
            S_tag_ms[1] <= 32'd0;
            S_tag_ms[2] <= 32'd0;
            S_tag_ms[3] <= 32'd0;
            S_tag_seen  <= 4'd0;
        end else begin
            // ---- 毫秒计数（自由回绕；两个 32 位值相减在模 2^32 下仍正确）----
            if (S_div_cnt == DIV - 24'd1) begin
                S_div_cnt <= 24'd0;
                S_ms      <= S_ms + 32'd1;
            end else begin
                S_div_cnt <= S_div_cnt + 24'd1;
            end

            // ---- 采集帧起始：给"这一帧将要写入的 BANK"打时间戳 ----
            //   ⚠ 必须在 `wp` **自增之前**取 I_wr_bank（video_in 同一拍把地址设为
            //     IMAGE_BASE_ADDR_{wp}，然后 wp 才 +1）⇒ 传进来的就是本帧的 BANK。
            if (I_wr_frame_start) begin
                S_tag_ms[I_wr_bank]   <= S_ms;
                S_tag_seen[I_wr_bank] <= 1'b1;
            end
        end
    end

    // ========================================================================
    // 2. 测量域：显示帧起始时取"正在读的 BANK"的标签 ⇒ 差值即延迟
    // ========================================================================
    //  ⚠ 先判 S_tag_seen，避免启动阶段读到未初始化的 0（会算出巨大值）。
    wire        tag_ok  = S_tag_seen[I_rd_bank];
    wire [31:0] lat_new = S_ms - S_tag_ms[I_rd_bank];
    wire        lat_ok  = tag_ok && (lat_new <= MAX_VALID_MS);
    wire        do_meas = I_rd_frame_start && lat_ok;

    // ---- 指数滑动平均：把值放大 2^AVG_SHIFT 倍保存，避免整数截断饿死 ----
    //   AVG_SHIFT = 0 时化简为 S_acc <= lat_new（即直通瞬时值）
    //   ★ 首样本**直接装载**（而不是从 0 慢慢爬），否则上电后要等 τ 才收敛，
    //     OSD 会先显示一个从 0 往上爬的假数字。
    reg [23:0] S_acc;
    reg        S_acc_init;
    // ---- 结果乒乓（送往 OSD 域）----
    //   ⚠ 位宽取 24（而不是 16）：`S_acc[23:AVG_SHIFT]` 在 AVG_SHIFT=0 时是 24 位，
    //     取 16 位会触发位宽截断告警。多 8 个触发器换掉一类告警，值得。
    reg [23:0] S_pp_val [0:1];
    reg        S_pp_vld [0:1];
    reg        S_pp_sel, S_pp_tgl;
    reg        S_send_d1;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_acc       <= 24'd0;
            S_acc_init  <= 1'b0;
            S_pp_val[0] <= 24'd0;
            S_pp_val[1] <= 24'd0;
            S_pp_vld[0] <= 1'b0;
            S_pp_vld[1] <= 1'b0;
            S_pp_sel    <= 1'b0;
            S_pp_tgl    <= 1'b0;
            S_send_d1   <= 1'b0;
        end else begin
            if (!S_acc_init) begin
                if (do_meas) begin
                    S_acc      <= (AVG_SHIFT == 0) ? {8'd0, lat_new[15:0]}
                                                   : ({8'd0, lat_new[15:0]} << AVG_SHIFT);
                    S_acc_init <= 1'b1;
                end
            end else begin
                S_acc <= S_acc - (S_acc >> AVG_SHIFT) + {8'd0, lat_new[15:0]};
            end
            S_send_d1 <= do_meas;

            // 打一拍再送出：此时 S_acc 已包含本次更新（更新率仅 ~60 Hz，1 拍无影响）
            if (S_send_d1) begin
                S_pp_val[S_pp_sel] <= S_acc[23:AVG_SHIFT];
                S_pp_vld[S_pp_sel] <= 1'b1;
                S_pp_sel           <= ~S_pp_sel;
                S_pp_tgl           <= ~S_pp_tgl;
            end
        end
    end

    // ========================================================================
    // 3. OSD 域：翻转标志同步 + 取走结果
    // ========================================================================
    reg S_tgl_s1, S_tgl_s2, S_tgl_s3;
    reg S_sel_s1, S_sel_s2;

    always @(posedge I_clk_dis or negedge I_rst_dis_n) begin
        if (!I_rst_dis_n) begin
            S_tgl_s1     <= 1'b0;
            S_tgl_s2     <= 1'b0;
            S_tgl_s3     <= 1'b0;
            S_sel_s1     <= 1'b0;
            S_sel_s2     <= 1'b0;
            O_latency_ms <= TAG_INIT[31:0];
            O_lat_valid  <= 1'b0;
        end else begin
            S_tgl_s1 <= S_pp_tgl;
            S_tgl_s2 <= S_tgl_s1;
            S_tgl_s3 <= S_tgl_s2;
            S_sel_s1 <= S_pp_sel;
            S_sel_s2 <= S_sel_s1;

            // 标志位变化 ⇒ 有一份新的结果；`~S_sel_s2` 正是刚写入的那一组
            // （写侧写完才翻 sel，故此刻 sel 已指向下一组）
            if (S_tgl_s2 ^ S_tgl_s3) begin
                O_latency_ms <= {8'd0, S_pp_val[~S_sel_s2]};
                O_lat_valid  <= S_pp_vld[~S_sel_s2];
            end
        end
    end

endmodule
