`timescale 1ns / 1ps
// tile_param_latch — 任务参数快照寄存器
// start_pulse 到来时一次性锁存 M/N/K/TM/TN/TK/QUANT；运行期间软件继续
// 写控制寄存器只改变下一次任务的配置，不影响当前任务使用的 lp_*。
`include "npu_defines.vh"

module tile_param_latch(
    input        clk,
    input        rst,
    input        start_pulse,
    input [`NPU_DIM_W-1:0]  cfg_m, cfg_n, cfg_k,
    input [`NPU_TILE_W-1:0] cfg_tm, cfg_tn,
    input [`NPU_TK_W-1:0]   cfg_tk,
    input [`NPU_QS_W-1:0]   cfg_qshift,
    output reg  [`NPU_DIM_W-1:0]  lp_m, lp_n, lp_k,
    output reg  [`NPU_TILE_W-1:0] lp_tm, lp_tn,
    output reg  [`NPU_TK_W-1:0]   lp_tk,
    output reg  [`NPU_QS_W-1:0]   lp_qs
);

    always @(posedge clk) begin
        if (rst) begin
            lp_m <= 6'd0; lp_n <= 6'd0; lp_k <= 6'd0;
            lp_tm <= 3'd0; lp_tn <= 3'd0; lp_tk <= 5'd0; lp_qs <= 5'd0;
        end else if (start_pulse) begin
            lp_m <= cfg_m;   lp_n <= cfg_n;   lp_k <= cfg_k;
            lp_tm <= cfg_tm; lp_tn <= cfg_tn; lp_tk <= cfg_tk;
            lp_qs <= cfg_qshift;
        end
    end
endmodule
