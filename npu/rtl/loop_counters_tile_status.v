// loop_counters_tile_status — 由 tile 计数器生成边界与调度状态:
// first_k_tile / last_k_tile / last_output_tile / valid_tm / valid_tn / valid_tk
`include "npu_defines.vh"

module loop_counters_tile_status(
    input  wire [`NPU_TIDX_W-1:0] tile_i, tile_j, tile_k,
    input  wire [`NPU_DIM_W-1:0]  lp_m, lp_n, lp_k,
    input  wire [`NPU_TILE_W-1:0] lp_tm, lp_tn,
    input  wire [`NPU_TK_W-1:0]   lp_tk,
    output wire        first_k_tile,
    output wire        last_k_tile,
    output wire        last_output_tile,
    output wire [`NPU_TILE_W-1:0] valid_tm,
    output wire [`NPU_TILE_W-1:0] valid_tn,
    output wire [`NPU_TK_W-1:0]   valid_tk
);

    wire [`NPU_TIDX_W-1:0] nt_i = (lp_m + lp_tm - 1) / lp_tm;
    wire [`NPU_TIDX_W-1:0] nt_j = (lp_n + lp_tn - 1) / lp_tn;
    wire [`NPU_TIDX_W-1:0] nt_k = (lp_k + lp_tk - 1) / lp_tk;

    assign first_k_tile     = (tile_k == 5'd0);
    assign last_k_tile      = (tile_k + 5'd1 >= nt_k);
    assign last_output_tile = (tile_i + 5'd1 >= nt_i) && (tile_j + 5'd1 >= nt_j);

    // 边界有效尺寸(越界部分由流控制补零 / 写回过滤)
    wire [`NPU_DIM_W-1:0] rem_m = lp_m - tile_i * lp_tm;   // 该 tile 起点后剩余行数, > 0
    wire [`NPU_DIM_W-1:0] rem_n = lp_n - tile_j * lp_tn;
    wire [`NPU_DIM_W-1:0] rem_k = lp_k - tile_k * lp_tk;

    assign valid_tm = (rem_m > {3'd0, lp_tm}) ? lp_tm : rem_m[`NPU_TILE_W-1:0];
    assign valid_tn = (rem_n > {3'd0, lp_tn}) ? lp_tn : rem_n[`NPU_TILE_W-1:0];
    assign valid_tk = (rem_k > {1'b0,  lp_tk}) ? lp_tk : rem_k[`NPU_TK_W-1:0];

endmodule
