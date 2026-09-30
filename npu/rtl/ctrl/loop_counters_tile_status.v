`timescale 1ns / 1ps
// loop_counters_tile_status — 从 Tile 计数器派生边界状态
//
// nt_i/nt_j/nt_k 是三个维度需要执行的 Tile 数量，采用向上取整。
// valid_tm/valid_tn/valid_tk 是当前 Tile 实际有效的尺寸；边界 Tile 可能
// 小于配置的 TM/TN/TK，越界输入由 lane_en 补零，越界 C 元素由写回控制过滤。
`include "npu_defines.vh"

module loop_counters_tile_status(
    input [`NPU_TIDX_W-1:0] tile_i, tile_j, tile_k,
    input [`NPU_DIM_W-1:0]  lp_m, lp_n, lp_k,
    input [`NPU_TILE_W-1:0] lp_tm, lp_tn,
    input [`NPU_TK_W-1:0]   lp_tk,
    output reg        first_k_tile,
    output reg        last_k_tile,
    output reg        last_output_tile,
    output reg [`NPU_TILE_W-1:0] valid_tm,
    output reg [`NPU_TILE_W-1:0] valid_tn,
    output reg [`NPU_TK_W-1:0]   valid_tk
);

    wire [`NPU_TIDX_W-1:0] nt_i = (lp_tm == 0) ? {`NPU_TIDX_W{1'b0}} :
                                    (lp_m + lp_tm - 1) / lp_tm;
    wire [`NPU_TIDX_W-1:0] nt_j = (lp_tn == 0) ? {`NPU_TIDX_W{1'b0}} :
                                    (lp_n + lp_tn - 1) / lp_tn;
    wire [`NPU_TIDX_W-1:0] nt_k = (lp_tk == 0) ? {`NPU_TIDX_W{1'b0}} :
                                    (lp_k + lp_tk - 1) / lp_tk;

    // 边界有效尺寸(越界部分由流控制补零 / 写回过滤)。
    // 配置检查保证任务运行时 lp_* 非零，因此这里不会发生非法减法路径。
    wire [`NPU_DIM_W-1:0] rem_m = lp_m - tile_i * lp_tm;   // 该 tile 起点后剩余行数, > 0
    wire [`NPU_DIM_W-1:0] rem_n = lp_n - tile_j * lp_tn;
    wire [`NPU_DIM_W-1:0] rem_k = lp_k - tile_k * lp_tk;

    always @(*) begin
        first_k_tile     = (tile_k == 5'd0);
        last_k_tile      = (tile_k + 5'd1 >= nt_k);
        last_output_tile = (tile_i + 5'd1 >= nt_i) && (tile_j + 5'd1 >= nt_j);
        valid_tm = (rem_m > {3'd0, lp_tm}) ? lp_tm : rem_m[`NPU_TILE_W-1:0];
        valid_tn = (rem_n > {3'd0, lp_tn}) ? lp_tn : rem_n[`NPU_TILE_W-1:0];
        valid_tk = (rem_k > {1'b0,  lp_tk}) ? lp_tk : rem_k[`NPU_TK_W-1:0];
    end

endmodule
