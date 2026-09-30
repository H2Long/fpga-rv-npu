`timescale 1ns / 1ps
// block_addr_gen — 当前 Tile 的三个基地址生成器
//
// A/BT Buffer 的地址单位是 32 位字：一个字包含同一 k 的四个 INT8。
// 因此 A/BT 的 tile 基地址分别由输出行/列 tile 和 K tile 决定：
//   A  = tile_i * K + tile_k * TK
//   BT = tile_j * K + tile_k * TK
// C Buffer 的地址单位是单个 32 位元素，采用行主序：
//   C  = (tile_i * TM) * N + tile_j * TN
`include "npu_defines.vh"

module block_addr_gen(
    input [`NPU_TIDX_W-1:0] tile_i, tile_j, tile_k,
    input [`NPU_DIM_W-1:0]  lp_n, lp_k,
    input [`NPU_TILE_W-1:0] lp_tm, lp_tn,
    input [`NPU_TK_W-1:0]   lp_tk,
    output reg [`NPU_ABUF_AW-1:0] a_base,
    output reg [`NPU_BBUF_AW-1:0] bt_base,
    output reg [`NPU_CBASE_W-1:0] c_base
);

    always @(*) begin
        // 这些表达式是组合地址计算，不在本模块中寄存；FSM 在阶段边界使用稳定地址。
        a_base  = tile_i * lp_k + tile_k * lp_tk;
        bt_base = tile_j * lp_k + tile_k * lp_tk;
        c_base  = (tile_i * lp_tm) * lp_n + tile_j * lp_tn;
    end

endmodule
