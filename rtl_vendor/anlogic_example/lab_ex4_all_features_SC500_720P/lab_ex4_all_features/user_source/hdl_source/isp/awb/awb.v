/*****************************************************************
Company : MiLianKe Electronic Technology Co., Ltd.
WebSite:https://www.milianke.com
TechWeb:https://www.uisrc.com
tmall-shop:https://milianke.tmall.com
jd-shop:https://milianke.jd.com
taobao-shop: https://milianke.taobao.com
Description:
AWB module refactored for P1a phase:
  - 8 dividers -> 2 dividers (R/B) with 4-phase TDM
  - 8 multipliers -> 2 multipliers (R/B) with 4-phase TDM
  - FIFO buffering between signal_delay and TDM multiplier section
  - Output valid is non-continuous (1 word per 4 cycles during active processing)
*****************************************************************/
module awb  #(
    parameter IMG_HEIGHT = 1080,
    parameter IMG_WIDTH  = 1920
)
(
    input                   I_clk  ,
    input                   I_rst_n,

    input                   I_tlast  ,
    input                   I_tuser  ,
    input [95:0]            I_tdata  ,
    input                   I_tvalid ,
    output                  I_tready ,

    output                  O_tlast  ,
    output                  O_tuser  ,
    output [95:0]           O_tdata  ,
    output                  O_tvalid ,
    input                   O_tready
);

  reg         I_tvalid_r0,I_tvalid_r1;
  reg  [95:0] I_tdata_d0,I_tdata_d1;

  reg  [31:0] sum_r[0:3];
  reg  [31:0] sum_g[0:3];
  reg  [31:0] sum_b[0:3];

  wire  [95:0] data_d0 ;
  wire         valid_d0;
  wire         I_tuser_r0;

  reg          I_tuser_r1;
  reg   [95:0] data_d1 ;
  reg          valid_d1;

  // Input pipeline
  always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        I_tdata_d0  <= 0;
        I_tdata_d1  <= 0;
        {I_tvalid_r0,I_tvalid_r1} <= 0;
    end else begin
        I_tdata_d0  <= I_tdata   ;
        I_tdata_d1  <= I_tdata_d0;
        I_tvalid_r0 <= I_tvalid;
        I_tvalid_r1 <= I_tvalid_r0;
    end
  end

  // Split 4 pixels into RGB components
  wire [7:0] rgb888_r_d0[0:3];
  wire [7:0] rgb888_g_d0[0:3];
  wire [7:0] rgb888_b_d0[0:3];

  assign  rgb888_r_d0[0] = I_tdata_d0[16+:8];
  assign  rgb888_g_d0[0] = I_tdata_d0[8+:8];
  assign  rgb888_b_d0[0] = I_tdata_d0[0+:8];

  assign  rgb888_r_d0[1] = I_tdata_d0[40+:8];
  assign  rgb888_g_d0[1] = I_tdata_d0[32+:8];
  assign  rgb888_b_d0[1] = I_tdata_d0[24+:8];

  assign  rgb888_r_d0[2] = I_tdata_d0[64+:8];
  assign  rgb888_g_d0[2] = I_tdata_d0[56+:8];
  assign  rgb888_b_d0[2] = I_tdata_d0[48+:8];

  assign  rgb888_r_d0[3] = I_tdata_d0[88+:8];
  assign  rgb888_g_d0[3] = I_tdata_d0[80+:8];
  assign  rgb888_b_d0[3] = I_tdata_d0[72+:8];

  // Accumulate RGB sums per phase
  always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n || I_tuser) begin
      sum_r[0] <= 0; sum_g[0] <= 0; sum_b[0] <= 0;
      sum_r[1] <= 0; sum_g[1] <= 0; sum_b[1] <= 0;
      sum_r[2] <= 0; sum_g[2] <= 0; sum_b[2] <= 0;
      sum_r[3] <= 0; sum_g[3] <= 0; sum_b[3] <= 0;
    end else if (I_tvalid_r0) begin
      sum_r[0] <= sum_r[0] + rgb888_r_d0[0];
      sum_g[0] <= sum_g[0] + rgb888_g_d0[0];
      sum_b[0] <= sum_b[0] + rgb888_b_d0[0];

      sum_r[1] <= sum_r[1] + rgb888_r_d0[1];
      sum_g[1] <= sum_g[1] + rgb888_g_d0[1];
      sum_b[1] <= sum_b[1] + rgb888_b_d0[1];

      sum_r[2] <= sum_r[2] + rgb888_r_d0[2];
      sum_g[2] <= sum_g[2] + rgb888_g_d0[2];
      sum_b[2] <= sum_b[2] + rgb888_b_d0[2];

      sum_r[3] <= sum_r[3] + rgb888_r_d0[3];
      sum_g[3] <= sum_g[3] + rgb888_g_d0[3];
      sum_b[3] <= sum_b[3] + rgb888_b_d0[3];
    end
  end

/*****************************************************************
                    TDM Dividers: 2 dividers, 4-phase
*****************************************************************/
  reg [1:0] div_ph;
  always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n)
      div_ph <= 2'd0;
    else
      div_ph <= div_ph + 2'd1;
  end

  wire [31:0] div_den_r = sum_r[div_ph];
  wire [31:0] div_den_b = sum_b[div_ph];
  wire [47:0] div_num   = {sum_g[div_ph], 16'd0};

  wire [47:0] dout_R;
  wire [47:0] dout_B;
  wire        done_R;

  divider div_R (
      .clk(I_clk),
      .rst(!I_rst_n),
      .start(I_tvalid_r1),
      .denominator(div_den_r),
      .numerator(div_num),
      .quotient(dout_R),
      .done(done_R)
  );

  divider div_B (
      .clk(I_clk),
      .rst(!I_rst_n),
      .start(I_tvalid_r1),
      .denominator(div_den_b),
      .numerator(div_num),
      .quotient(dout_B),
      .done()
  );

  // 50-cycle divider latency: out_ph = (div_ph - 50) mod 4 = (div_ph + 2) mod 4
  wire [1:0] out_ph = div_ph + 2'd2;

  // Gain registers per phase
  reg [19:0] in_r_r[0:3];
  reg [19:0] in_b_r[0:3];

  genvar gi;
  generate
    for(gi = 0; gi < 4; gi = gi + 1) begin : gain_reg_gen
      always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n || I_tuser) begin
          in_r_r[gi] <= 20'h10000;
          in_b_r[gi] <= 20'h10000;
        end else begin
          if(done_R && (out_ph == gi[1:0])) begin
            in_r_r[gi] <= (|dout_R[47:20]) ? 20'hfffff : dout_R[19:0];
          end
          if(done_R && (out_ph == gi[1:0])) begin
            in_b_r[gi] <= (|dout_B[47:20]) ? 20'hfffff : dout_B[19:0];
          end
        end
      end
    end
  endgenerate

/*****************************************************************
                    Signal delay (BRAM)
*****************************************************************/
  signal_delay #(
      .IMG_HEIGHT   (IMG_HEIGHT),
      .IMG_WIDTH    (IMG_WIDTH ),
      .DATA_WIDTH   (96  ),
      .DELAY_CYCLE  (54)
  )signal_delay_d (
       .I_clk  (I_clk  ),
       .I_rst_n(I_rst_n),
       .I_tuser(I_tuser),
       .I_valid(I_tvalid_r1),
       .I_data (I_tdata_d1 ),
       .O_valid(valid_d0   ),
       .O_data (data_d0    ),
       .O_tuser(I_tuser_r0 )
  );

  always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        valid_d1 <= 0;
        data_d1  <= 0;
        I_tuser_r1 <= 0;
    end else begin
        valid_d1 <= valid_d0;
        data_d1  <= data_d0 ;
        I_tuser_r1 <= I_tuser_r0;
    end
  end

/*****************************************************************
              TDM Multipliers: 2 multipliers, 4-phase
              with FIFO buffering for rate conversion
*****************************************************************/
  // Delay tlast to align with data_d1 (2-cycle pipeline match)
  reg I_tlast_r0, I_tlast_r1;
  always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
      I_tlast_r0 <= 0;
      I_tlast_r1 <= 0;
    end else begin
      I_tlast_r0 <= I_tlast;
      I_tlast_r1 <= I_tlast_r0;
    end
  end

  // FIFO: pack {tlast, tuser, data[95:0]} into 155-bit FIFO
  wire         fifo_wr   = valid_d1;
  wire [154:0] fifo_din  = {57'd0, I_tlast_r1, I_tuser_r1, data_d1};
  wire         fifo_rd;
  wire [154:0] fifo_dout;
  wire         fifo_empty;

  w155_d512_fifo u_awb_fifo (
      .rst       (!I_rst_n),
      .clk       (I_clk),
      .we        (fifo_wr),
      .di        (fifo_din),
      .re        (fifo_rd),
      .dout      (fifo_dout),
      .valid     (),
      .full_flag (),
      .empty_flag(fifo_empty),
      .afull     (),
      .aempty    (),
      .wrusedw   (),
      .rdusedw   ()
  );

  // TDM phase counter and FIFO read control
  reg [1:0]  mul_ph;
  reg        mul_busy;
  reg [95:0] word_r;
  reg        word_tuser_r;
  reg        word_tlast_r;

  assign fifo_rd = !mul_busy && !fifo_empty;

  always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
      mul_ph <= 2'd0;
      mul_busy <= 1'b0;
      word_r <= 0;
      word_tuser_r <= 1'b0;
      word_tlast_r <= 1'b0;
    end else if(fifo_rd) begin
      word_r <= fifo_dout[95:0];
      word_tuser_r <= fifo_dout[96];
      word_tlast_r <= fifo_dout[97];
      mul_ph <= 2'd0;
      mul_busy <= 1'b1;
    end else if(mul_busy) begin
      mul_ph <= mul_ph + 2'd1;
      if(mul_ph == 2'd3)
        mul_busy <= 1'b0;
    end
  end

  // Current pixel selection based on mul_ph
  // word_r layout: {px3[R,G,B], px2[R,G,B], px1[R,G,B], px0[R,G,B]}
  // each pixel: R=[16+:8], G=[8+:8], B=[0+:8]
  wire [7:0] cur_r = word_r[{mul_ph, 5'd16} +: 8];
  wire [7:0] cur_g = word_r[{mul_ph, 5'd8} +: 8];
  wire [7:0] cur_b = word_r[{mul_ph, 5'd0} +: 8];

  wire [19:0] cur_in_r = in_r_r[mul_ph];
  wire [19:0] cur_in_b = in_b_r[mul_ph];

  // 2 shared multipliers (1 for R, 1 for B), results stored per phase
  reg [27:0] R_new_r[0:3];
  reg [27:0] B_new_r[0:3];
  reg [7:0]  G_new_r[0:3];

  // Single multiplier pipeline stage: compute product every cycle
  reg [27:0] mul_r_d1;
  reg [27:0] mul_b_d1;
  reg [7:0]  mul_g_d1;
  reg [1:0]  mul_ph_d1;

  always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
      mul_r_d1 <= 0;
      mul_b_d1 <= 0;
      mul_g_d1 <= 0;
      mul_ph_d1 <= 2'd0;
    end else begin
      mul_r_d1 <= cur_in_r * cur_r;
      mul_b_d1 <= cur_in_b * cur_b;
      mul_g_d1 <= cur_g;
      mul_ph_d1 <= mul_ph;
    end
  end

  // Route multiplier results to the correct phase register
  integer mii;
  always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
      for(mii = 0; mii < 4; mii = mii + 1) begin
        R_new_r[mii] <= 0;
        B_new_r[mii] <= 0;
        G_new_r[mii] <= 0;
      end
    end else begin
      R_new_r[mul_ph_d1] <= mul_r_d1;
      B_new_r[mul_ph_d1] <= mul_b_d1;
      G_new_r[mul_ph_d1] <= mul_g_d1;
    end
  end

/*****************************************************************
                    Pixel value truncation
*****************************************************************/
  wire [7:0] R_new_x1 = (R_new_r[0][27:24]) ? 8'd255 : R_new_r[0][23:16];
  wire [7:0] G_new_x1 = G_new_r[0];
  wire [7:0] B_new_x1 = (B_new_r[0][27:24]) ? 8'd255 : B_new_r[0][23:16];

  wire [7:0] R_new_x2 = (R_new_r[1][27:24]) ? 8'd255 : R_new_r[1][23:16];
  wire [7:0] G_new_x2 = G_new_r[1];
  wire [7:0] B_new_x2 = (B_new_r[1][27:24]) ? 8'd255 : B_new_r[1][23:16];

  wire [7:0] R_new_x3 = (R_new_r[2][27:24]) ? 8'd255 : R_new_r[2][23:16];
  wire [7:0] G_new_x3 = G_new_r[2];
  wire [7:0] B_new_x3 = (B_new_r[2][27:24]) ? 8'd255 : B_new_r[2][23:16];

  wire [7:0] R_new_x4 = (R_new_r[3][27:24]) ? 8'd255 : R_new_r[3][23:16];
  wire [7:0] G_new_x4 = G_new_r[3];
  wire [7:0] B_new_x4 = (B_new_r[3][27:24]) ? 8'd255 : B_new_r[3][23:16];

/*****************************************************************
                    Output synchronization
*****************************************************************/
  // Capture tuser/tlast at last phase (mul_ph==3) so they survive
  // the potential FIFO re-read on the following cycle
  reg word_tuser_cap;
  reg word_tlast_cap;
  always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
      word_tuser_cap <= 1'b0;
      word_tlast_cap <= 1'b0;
    end else if(mul_busy && (mul_ph == 2'd3)) begin
      word_tuser_cap <= word_tuser_r;
      word_tlast_cap <= word_tlast_r;
    end
  end

  // Output valid pulse: one cycle after mul_busy falls (all 4 results settled)
  reg mul_busy_d1;
  always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n)
      mul_busy_d1 <= 1'b0;
    else
      mul_busy_d1 <= mul_busy;
  end

  wire out_valid_w = mul_busy_d1 && !mul_busy;

  // Extra pipeline stage to match multiplier latency (R_new_r[3] settles
  // one cycle after mul_busy falls)
  reg out_valid_d1;
  always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n)
      out_valid_d1 <= 1'b0;
    else
      out_valid_d1 <= out_valid_w;
  end

  reg        O_tvalid_r;
  reg [95:0] O_tdata_r;
  reg        O_tuser_r;
  reg        O_tlast_r;

  always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
      O_tvalid_r <= 1'b0;
      O_tdata_r  <= 0;
      O_tuser_r  <= 1'b0;
      O_tlast_r  <= 1'b0;
    end else begin
      O_tvalid_r <= out_valid_d1;
      if(out_valid_d1) begin
        O_tdata_r <= {R_new_x4,G_new_x4,B_new_x4,
                      R_new_x3,G_new_x3,B_new_x3,
                      R_new_x2,G_new_x2,B_new_x2,
                      R_new_x1,G_new_x1,B_new_x1};
        O_tuser_r <= word_tuser_cap;
        O_tlast_r <= word_tlast_cap;
      end
    end
  end

  assign  O_tlast  = O_tlast_r;
  assign  O_tuser  = O_tuser_r;
  assign  O_tdata  = O_tdata_r;
  assign  O_tvalid = O_tvalid_r;

  assign  I_tready = O_tready;

endmodule