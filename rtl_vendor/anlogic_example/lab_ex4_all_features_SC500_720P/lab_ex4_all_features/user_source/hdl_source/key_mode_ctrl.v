// key_mode_ctrl.v -- 按键模式控制器
//
// ★ 2026-09-20 红线1 改造后的行为：
//     KEY0（I_button[0]，板载 KEY1/D5）短按：模式号 **依次循环**
//         0 原图 -> 1 灰度 -> 2 二值化 -> 3 反色 -> 0 ...
//     KEY1（I_button[1]，板载 KEY2/A9）**不改模式**，专职 AE 增益调节
//     （两键长按均透给 ae_set 做 AE 连续调节）
//
//   改造前：KEY0 翻 O_mode[0]、KEY1 翻 O_mode[1]，两位语义独立
//     （bit0=边缘检测使能 / bit1=OSD 使能）。
//   红线1 把 mode[1:0] 变成完整模式号后，"独立翻位"会让 KEY0 只能在
//   原图<->灰度 之间跳，永远到不了二值化/反色，与演示脚本的
//   "K1 依次切换"不符，故改为循环。OSD 已改为恒开，不再由按键控制。
//
// 门控原理：未达长按阈值时 O_btn_ae 恒为高（ae_set 看不到按键），
//           长按建立后 O_btn_ae 拉低传递给 ae_set，本次按下不再触发模式切换

module key_mode_ctrl #(
    parameter integer CLK_FREQ_HZ  = 23810000,   // 输入时钟频率，实测 23.81MHz
    parameter integer DEBOUNCE_MS  = 20,         // 去抖时长(ms)
    parameter integer LONGPRESS_MS = 500         // 长短按分界(ms)
)(
    input  wire       I_clk,        // 23.81MHz
    input  wire       I_rst_n,      // 低有效异步复位（复位源是 PLL lock）
    input  wire [1:0] I_button,     // 原始异步按键，低有效（0=按下）
    output reg  [2:0] O_mode,       // 模式寄存器（P4 扩为 3 位：0..7），复位值 3'b000
    output reg  [1:0] O_btn_ae,     // 门控后的按键，低有效，复位值 2'b11
    // ★ P6 新增：短按 KEY2 → AE 自动/手动切换脉冲（单拍，高有效）
    //   为什么用 KEY2 短按：它原来**是空的**（红线1 之后 KEY1 短按专职切模式，
    //   KEY2 短按没有任何功能）⇒ 不占用任何既有手势，也不与长按调 AG 冲突。
    output reg        O_auto_tog
);

    // ================================================================
    // 1. clogb2 函数（Verilog-2001 兼容的 ceil(log2) 替代 $clog2）
    //    与本工程 uial2axis.v 风格一致
    // ================================================================
    function integer clogb2(input integer bit_depth);
        begin
            for (clogb2 = 0; bit_depth > 0; clogb2 = clogb2 + 1)
                bit_depth = bit_depth >> 1;
        end
    endfunction

    // ================================================================
    // 2. 计数周期与位宽（全部由参数推导，不硬编码）
    // ================================================================
    localparam integer DEBOUNCE_CYC  = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;   // 默认 476200
    localparam integer LONGPRESS_CYC = (CLK_FREQ_HZ / 1000) * LONGPRESS_MS;  // 默认 11905000

    // clogb2(0)=0，位宽保底为 1（DEBOUNCE_MS=0 时仍合法）
    localparam integer DEB_W = (clogb2(DEBOUNCE_CYC)  > 0) ? clogb2(DEBOUNCE_CYC)  : 1;
    localparam integer LP_W  = (clogb2(LONGPRESS_CYC) > 0) ? clogb2(LONGPRESS_CYC) : 1;

    // ================================================================
    // 3. 输入同步 —— 两级 DFF，复位值 2'b11（释放态）
    //    禁止对原始 I_button 做组合边沿检测
    // ================================================================
    reg [1:0] S_sync_s1;   // 同步第 1 级
    reg [1:0] S_sync_s2;   // 同步第 2 级（可用）

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_sync_s1 <= 2'b11;
            S_sync_s2 <= 2'b11;
        end else begin
            S_sync_s1 <= I_button;
            S_sync_s2 <= S_sync_s1;
        end
    end

    // ================================================================
    // 4. 去抖 —— 电平持续 DEBOUNCE_CYC 个周期不变才更新稳定值
    //    中途电平变回与稳定值一致时计数清零
    // ================================================================
    reg [1:0]        S_btn_stable;       // 去抖后电平（1=释放，0=按下）
    reg [DEB_W-1:0]  S_deb_cnt_0;       // 按键 0 去抖计数器
    reg [DEB_W-1:0]  S_deb_cnt_1;       // 按键 1 去抖计数器

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_btn_stable <= 2'b11;
            S_deb_cnt_0  <= {DEB_W{1'b0}};
            S_deb_cnt_1  <= {DEB_W{1'b0}};
        end else begin
            // ---- 按键 0 去抖 ----
            if (S_sync_s2[0] != S_btn_stable[0]) begin
                if (S_deb_cnt_0 >= DEBOUNCE_CYC - 1) begin
                    S_btn_stable[0] <= S_sync_s2[0];
                    S_deb_cnt_0     <= {DEB_W{1'b0}};
                end else begin
                    S_deb_cnt_0 <= S_deb_cnt_0 + 1'b1;
                end
            end else begin
                S_deb_cnt_0 <= {DEB_W{1'b0}};
            end
            // ---- 按键 1 去抖 ----
            if (S_sync_s2[1] != S_btn_stable[1]) begin
                if (S_deb_cnt_1 >= DEBOUNCE_CYC - 1) begin
                    S_btn_stable[1] <= S_sync_s2[1];
                    S_deb_cnt_1     <= {DEB_W{1'b0}};
                end else begin
                    S_deb_cnt_1 <= S_deb_cnt_1 + 1'b1;
                end
            end else begin
                S_deb_cnt_1 <= {DEB_W{1'b0}};
            end
        end
    end

    // ================================================================
    // 5. 按键有效电平（组合逻辑）
    //    S_pressed[i]=1 表示按键 i 处于按下态
    // ================================================================
    wire [1:0] S_pressed;
    assign S_pressed = ~S_btn_stable;

    // ================================================================
    // 6. 长按判定（每键独立）
    //    按下期间累加计数，达到 LONGPRESS_CYC 后置位 S_in_long 并饱和保持；
    //    释放时清零计数器和标志。
    //    只有 S_in_long=1 的按下才会被门控到 ae_set
    // ================================================================
    reg [LP_W-1:0] S_lp_cnt_0;     // 按键 0 长按计时
    reg [LP_W-1:0] S_lp_cnt_1;     // 按键 1 长按计时
    reg            S_in_long_0;    // 按键 0 长按标志
    reg            S_in_long_1;    // 按键 1 长按标志

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_lp_cnt_0  <= {LP_W{1'b0}};
            S_lp_cnt_1  <= {LP_W{1'b0}};
            S_in_long_0 <= 1'b0;
            S_in_long_1 <= 1'b0;
        end else begin
            // ---- 按键 0 长按 ----
            if (S_pressed[0]) begin
                if (!S_in_long_0) begin
                    if (S_lp_cnt_0 >= LONGPRESS_CYC - 1)
                        S_in_long_0 <= 1'b1;   // 达到阈值，进入长按态
                    else
                        S_lp_cnt_0 <= S_lp_cnt_0 + 1'b1;
                end
                // S_in_long_0=1 后计数器与标志均饱和保持，不回绕
            end else begin
                S_lp_cnt_0  <= {LP_W{1'b0}};
                S_in_long_0 <= 1'b0;
            end
            // ---- 按键 1 长按 ----
            if (S_pressed[1]) begin
                if (!S_in_long_1) begin
                    if (S_lp_cnt_1 >= LONGPRESS_CYC - 1)
                        S_in_long_1 <= 1'b1;
                    else
                        S_lp_cnt_1 <= S_lp_cnt_1 + 1'b1;
                end
            end else begin
                S_lp_cnt_1  <= {LP_W{1'b0}};
                S_in_long_1 <= 1'b0;
            end
        end
    end

    // ================================================================
    // 7. 释放边沿检测 + 模式翻转
    //    短按释放（S_in_long=0）→ 翻转 O_mode 对应位
    //    长按释放（S_in_long=1）→ 不翻转，本次按下仅用于 AE 调节
    // ================================================================
    reg [1:0] S_pressed_d;   // S_pressed 打一拍，用于下降沿检测

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            S_pressed_d <= 2'b00;
            O_mode      <= 3'b000;
            O_auto_tog  <= 1'b0;
        end else begin
            S_pressed_d <= S_pressed;
            O_auto_tog  <= 1'b0;      // ★ 默认单拍
            // ---- KEY0 短按释放沿：模式号**加一循环**（★ 红线1 改造）----
            //   原实现是 `O_mode[0] <= ~O_mode[0]`（翻转 1 位）。
            //   红线1 把 mode[1:0] 变成完整模式号（0 原图/1 灰度/2 二值化/3 反色）后，
            //   独立翻位会导致"KEY0 只能在 原图<->灰度 之间跳"，永远到不了
            //   二值化/反色，与演示脚本"K1 依次切换"不符。
            //   故改为 0->1->2->3->0 依次循环。
            if (S_pressed_d[0] && !S_pressed[0]) begin
                if (!S_in_long_0) begin
                    // P4：模式共 5 个（0 原图/1 灰度/2 二值化/3 反色/4 卡通），
                    //     取模 5 循环；不用位宽自然回绕（那会经过未定义的 5/6/7）。
                    if (O_mode >= 3'd4) O_mode <= 3'd0;
                    else                O_mode <= O_mode + 3'd1;
                end
            end
            // ---- KEY1 短按：**不再改模式**，★ P6 起改为"AE 自动/手动切换" ----
            //   （原为翻转 O_mode[1]，而 O_mode[1] 曾是"OSD 使能"；
            //     红线1 后 OSD 已恒开、mode[1] 为模式号高位，故此处一直空着。
            //     长按 KEY1 仍经 O_btn_ae[1] 透给 ae_set 调 AE/AG。）
            if (S_pressed_d[1] && !S_pressed[1]) begin
                if (!S_in_long_1) O_auto_tog <= 1'b1;
            end
        end
    end

    // ================================================================
    // 8. AE 门控输出（寄存器输出，避免组合毛刺）
    //    长按且按键仍按住 → O_btn_ae=0（ae_set 可见，执行增益调节）
    //    其余情况         → O_btn_ae=1（ae_set 看不到按键）
    //    对 ae_set 而言一拍延迟无影响
    // ================================================================
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_btn_ae <= 2'b11;
        end else begin
            O_btn_ae[0] <= (S_in_long_0 && S_pressed[0]) ? 1'b0 : 1'b1;
            O_btn_ae[1] <= (S_in_long_1 && S_pressed[1]) ? 1'b0 : 1'b1;
        end
    end

endmodule
