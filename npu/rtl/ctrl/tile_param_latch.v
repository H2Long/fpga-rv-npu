// tile_param_latch — start_pulse 到来时锁存 M/N/K/TM/TN/TK/QUANT,
// 运行期间软件寄存器变化不会影响当前任务。
`include "npu_defines.vh"

module tile_param_latch(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start_pulse,
    input  wire [`NPU_DIM_W-1:0]  cfg_m, cfg_n, cfg_k,
    input  wire [`NPU_TILE_W-1:0] cfg_tm, cfg_tn,
    input  wire [`NPU_TK_W-1:0]   cfg_tk,
    input  wire [`NPU_QS_W-1:0]   cfg_qshift,
    output reg  [`NPU_DIM_W-1:0]  lp_m, lp_n, lp_k,
    output reg  [`NPU_TILE_W-1:0] lp_tm, lp_tn,
    output reg  [`NPU_TK_W-1:0]   lp_tk,
    output reg  [`NPU_QS_W-1:0]   lp_qs
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lp_m <= 6'd0; lp_n <= 6'd0; lp_k <= 6'd0;
            lp_tm <= 3'd0; lp_tn <= 3'd0; lp_tk <= 5'd0; lp_qs <= 5'd0;
        end else if (start_pulse) begin
            lp_m <= cfg_m;   lp_n <= cfg_n;   lp_k <= cfg_k;
            lp_tm <= cfg_tm; lp_tn <= cfg_tn; lp_tk <= cfg_tk;
            lp_qs <= cfg_qshift;
        end
    end
endmodule
