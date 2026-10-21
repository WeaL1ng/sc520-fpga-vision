// ============================================================
//  tb_smoke.v — ModelSim 接入自检 testbench
//
//  目的：用**最小**的方式证明三件事：
//     1) ModelSim 能编译本 testbench
//     2) 能链接到刚编好的 anl_ph1p 库（实例化安路原语 PH1P_PHY_GSR）
//     3) 能跑到 $finish 并打印结果
//
//  它**不**依赖任何加密 IP（hdmi_1_4b_/alc_mc_top_/byte_aligner 等都不需要），
//  所以只要有 vsim 许可证就一定能跑通 —— 适合用来区分
//  "环境没配好" 和 "许可证没配好" 这两类问题。
//
//  运行：
//     cd sim
//     vlib work
//     vlog -work work tb_smoke.v
//     vsim -c -L anl_common -L anl_ph1p -work work tb_smoke -do "run -all; quit -f"
//
//  预期输出末尾：
//     [SMOKE] 安路原语 PH1P_PHY_GSR 例化成功
//     [SMOKE] PASS
// ============================================================
`timescale 1ns/1ps

module tb_smoke;

    // ---- 1) 实例化安路 PH1P 全局复位原语（来自 anl_ph1p 库）----
    //     注意 PD 中 PH1P_PHY_GSR 无端口；例化它可以直接证明库链接成功。
    PH1P_PHY_GSR u_gsr();

    // ---- 2) 一个占位 DUT：验证时序与显示都正常 ----
    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    wire [7:0] cnt;

    always #5 clk = ~clk;          // 100 MHz

    reg [7:0] q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) q <= 8'd0;
        else        q <= q + 8'd1;
    end
    assign cnt = q;

    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // ---- 3) 主流程 ----
    initial begin
        $display("[SMOKE] ================================");
        $display("[SMOKE] ModelSim 接入自检开始");
        $display("[SMOKE] 时间刻度 1ns/1ps，时钟周期 10ns");
        $display("[SMOKE] ================================");

        #1;
        $display("[SMOKE] 安路原语 PH1P_PHY_GSR 例化成功");

        #100 rst_n = 1'b1;         // 释放复位

        repeat (20) @(posedge clk);
        $display("[SMOKE] 20 拍后 cnt = %0d (期望 20)", cnt);
        if (cnt !== 8'd20) begin
            $display("[SMOKE] FAIL: 计数器不符");
            $finish;
        end

        $display("[SMOKE] PASS");
        $display("[SMOKE] 说明：库链接 OK、时序推进 OK、令牌 OK");
        #50;
        $finish;
    end

    // 超时保护
    initial begin
        #10000;
        $display("[SMOKE] FAIL: 超时（10us 未结束）");
        $finish;
    end

endmodule
