/*******************************MILIANKE*******************************
*Company : MiLianKe Electronic Technology Co., Ltd.
*WebSite:https://www.milianke.com
*TechWeb:https://www.uisrc.com
*tmall-shop:https://milianke.tmall.com
*jd-shop:https://milianke.jd.com
*taobao-shop1: https://milianke.taobao.com
*Create Date: 2023/03/23
*Module Name:
*File Name:
*Description: 
*The reference demo provided by Milianke is only used for learning. 
*We cannot ensure that the demo itself is free of bugs, so users 
*should be responsible for the technical problems and consequences
*caused by the use of their own products.
*Copyright: Copyright (c) MiLianKe
*All rights reserved.
*Revision: 1.0
*Signal description
*1) I_ input
*2) O_ output
*3) IO_ input output
*4) S_ system internal signal
*5) _n activ low
*6) _dg debug signal 
*7) _r delay or register
*8) _s state mechine
*********************************************************************/
/*********ae_set �ֶ��������AE ***********
--�汾��1.0
*********************************************************************/
// ============================================================================
//  ★ 2026-09-21 P6 改造：**自动 / 手动双模**
// ----------------------------------------------------------------------------
//  改造原则：**手动路径一个字节都不改**（它是已验证可用的回退方案），
//            自动路径只是"多了一个目标值来源"。
//
//    w_ae_set = I_auto_en ? I_ae_auto : r_ae_set      // r_ae_set 仍是按键维护的手动目标
//    w_ag_set = I_auto_en ? I_ag_auto : r_ag_set
//
//  下游"提交 + I2C 握手"逻辑（r_ae / r_ag / r_ae_req / cfg_done 门控）**完全不动**：
//  自动与手动共用同一条写传感器的通路 ⇒ 不会出现"自动能用但手动失效"。
//
//  ⚠ 自动模式下**屏蔽手动按键对目标的修改**（`!I_auto_en` 才更新 r_ae_set/r_ag_set）。
//    否则长按按键会悄悄改掉手动目标，切回手动时画面突变，难以排查。
//
//  ⚠ 手动的 AG 上限由 `I_ag_max` 给（默认 16'd89）：
//    `SC500GainTbl` 的表在索引 73（0x0F29）就断了，但前两个十倍段都写满到
//    0x3F ⇒ 第三个十倍段疑似漏写（详见 ae_ctrl.v 头注释）。把上限做成端口，
//    是为了"自动/手动两条路径的上限永远一致"，避免出现"自动能上 111、
//    手动只能 89"这种自相矛盾的可观测行为。
// ============================================================================

module ae_set
(
input wire I_clk,
input wire I_rst,
input wire [3:0]I_btn,
input wire I_ae_cfg_done,
input wire I_cam_cfg_done,
// ---- ★ P6 新增：自动 / 手动 ----
input wire        I_auto_en,     // 1 = 自动（由 ae_ctrl 给目标）
input wire [15:0] I_ae_auto,     // 自动目标 AE
input wire [15:0] I_ag_auto,     // 自动目标 AG
input wire [15:0] I_ag_max,      // 手动 AG 上限（与 ae_ctrl.AG_MAX 保持一致）
output wire O_ae_req,
output wire [15:0] O_ae,
output wire [15:0] O_ag
);
	

reg 	[19:0] 	rc_ae_tick = 0; 
reg 			r_ae_tick = 0; 
reg 	[4:0] 	rc_ag_tick = 0; 
reg 			r_ag_tick = 0; 
	
always @(posedge I_clk or posedge I_rst) begin
	if(I_rst) begin
		rc_ae_tick <= 0; 
		r_ae_tick <= 0; 
		rc_ag_tick <= 0; 
		r_ag_tick <= 0; 
	end else begin
	//	Trigger AE Inc / Dec per 1 ms. 
		rc_ae_tick <= rc_ae_tick + 1; 
		r_ae_tick <= 0; 
		if(rc_ae_tick >= 99999) begin
			rc_ae_tick <= 0; 
			r_ae_tick <= 1; 
		end 
	//	Trigger AG Inc / Dec per 32 ms. 
		rc_ag_tick <= rc_ag_tick + r_ae_tick; 
		r_ag_tick <= (&rc_ag_tick) && r_ae_tick; 
	end
end
	
//	Use button to add / sub idelay values. I_button[0]:IncDatDly, [1]DecDatDly, [2]IncI_clkDly, [3]DecI_clkDly
reg 	[3:0] 	r_button_0 = 0, r_button_1 = 0; 
// SC520CS HD 60 fps mode uses VTS=1000.  Exposure 1991 is the legal max
// (half-line units), already close to the legal maximum.  AG=48 maps through
// SC520GainTbl: 144 -> 0x3e09=0x0f / 0x3e06=0x00 / 0x3e07=0x80 = 16x analogue.
reg 	[15:0] 	r_ae_set = 1991, r_ag_set = 144; 
always @(posedge I_clk or posedge I_rst) begin
	if(I_rst) begin
		r_button_0 <= 0; 
		r_button_1 <= 0; 
		r_ae_set <= 1991; 
		r_ag_set <= 144; 
	end else begin
	//	When button pressed, r_button_1 bit is 1. 
		r_button_0 <= ~I_btn; 
		r_button_1 <= r_button_0; 
	
	//	★ P6：**自动模式下屏蔽手动按键**（否则长按会悄悄改掉手动目标，
	//	   切回手动时画面突变，很难排查）。短按 KEY2 可切回手动（见 key_mode_ctrl.v）
		if(!I_auto_en) begin
		if(r_button_1[0]) begin
			r_ae_set <= (r_ae_set > 2) ? r_ae_set - r_ae_tick : r_ae_set; 
		end else if(r_button_1[1]) begin
			r_ae_set <= (r_ae_set < 1991) ? r_ae_set + r_ae_tick : r_ae_set; 
		end 
		if(r_button_1[2]) begin
				r_ag_set <= (r_ag_set > 16) ? r_ag_set - r_ag_tick : r_ag_set; 
		end else if(r_button_1[3]) begin
				r_ag_set <= (r_ag_set < I_ag_max) ? r_ag_set + r_ag_tick : r_ag_set; 
		end 
		end
		end
	end
	
//	★ P6：目标值来源 = 自动 ? ae_ctrl : 手动按键
//	两个来源都不改动作的位宽/握手，只是"谁来定目标"不同。
wire [15:0] w_ae_set = I_auto_en ? I_ae_auto : r_ae_set;
wire [15:0] w_ag_set = I_auto_en ? I_ag_auto : r_ag_set;
	
//	Update AG / AE when changed. 
reg 	[15:0] 	r_ae ; 
reg 	[15:0] 	r_ag ; 
reg 			r_ae_req = 0; //synthesis keep
assign O_ae = r_ae;
assign O_ag = r_ag;
assign O_ae_req = r_ae_req;

always @(posedge I_clk or posedge I_rst) begin
	if(I_rst) begin
		r_ae_req <= 0; 
		r_ae     <= 1991; 
		r_ag     <= 17; 
	end else if(r_ae_req) begin
		r_ae_req <= 0; 
	end else if(((r_ae != w_ae_set) || (r_ag != w_ag_set))&&(I_cam_cfg_done==1'b1)&&(I_ae_cfg_done==1'b1)) begin
		r_ae     <= w_ae_set; 
		r_ag     <= w_ag_set; 
		r_ae_req <= 1; 
	end
end


endmodule


	
