`timescale 1ns / 1ps
// tile_scheduler — 三层 Tile 循环计数器
//
// 循环顺序等价于：
//   for tile_i = 0 .. nt_i-1
//     for tile_j = 0 .. nt_j-1
//       for tile_k = 0 .. nt_k-1
//
// next_k_req 只推进 K 维；next_out_req 完成当前输出 Tile 后清零 tile_k，
// 再推进 tile_j，tile_j 到末尾时回零并推进 tile_i。
`include "npu_defines.vh"

module tile_scheduler(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        sched_init,     // 任务开始:三个计数器清零
    input  wire        next_k_req,     // tile_k + 1
    input  wire        next_out_req,   // tile_j+1, 或 tile_j 回 0 且 tile_i+1;tile_k 回 0
    input  wire [`NPU_DIM_W-1:0]  lp_m, lp_n, lp_k,
    input  wire [`NPU_TILE_W-1:0] lp_tm, lp_tn,
    input  wire [`NPU_TK_W-1:0]   lp_tk,
    output reg  [`NPU_TIDX_W-1:0] tile_i, tile_j, tile_k
);

    // tile 总数(由参数计算)
    wire [`NPU_TIDX_W-1:0] nt_i = (lp_tm == 0) ? {`NPU_TIDX_W{1'b0}} :
                                    (lp_m + lp_tm - 1) / lp_tm;
    wire [`NPU_TIDX_W-1:0] nt_j = (lp_tn == 0) ? {`NPU_TIDX_W{1'b0}} :
                                    (lp_n + lp_tn - 1) / lp_tn;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tile_i <= 5'd0; tile_j <= 5'd0; tile_k <= 5'd0;
        end else if (sched_init) begin
            tile_i <= 5'd0; tile_j <= 5'd0; tile_k <= 5'd0;
        end else if (next_k_req) begin
            tile_k <= tile_k + 5'd1;
        end else if (next_out_req) begin
            tile_k <= 5'd0;
            if (tile_j + 5'd1 >= nt_j) begin
                tile_j <= 5'd0;
                tile_i <= tile_i + 5'd1;
            end else begin
                tile_j <= tile_j + 5'd1;
            end
        end
    end
endmodule
