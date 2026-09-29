// block_addr_gen — 根据当前 tile 下标计算 A/BT 的字基地址与 C 的元素基地址
// A 字地址  = tile_i*K + tile_k*TK   (一行 tile = TM 行 x 同一 k 打包成 1 个字)
// BT 字地址 = tile_j*K + tile_k*TK
// C 元素地址 = tile_i*TM*N + tile_j*TN(行主序)
`include "npu_defines.vh"

module block_addr_gen(
    input  wire [`NPU_TIDX_W-1:0] tile_i, tile_j, tile_k,
    input  wire [`NPU_DIM_W-1:0]  lp_n, lp_k,
    input  wire [`NPU_TILE_W-1:0] lp_tm, lp_tn,
    input  wire [`NPU_TK_W-1:0]   lp_tk,
    output wire [`NPU_ABUF_AW-1:0] a_base,
    output wire [`NPU_BBUF_AW-1:0] bt_base,
    output wire [`NPU_CBASE_W-1:0] c_base
);

    assign a_base  = (tile_i * lp_k + tile_k * lp_tk);
    assign bt_base = (tile_j * lp_k + tile_k * lp_tk);
    assign c_base  = (tile_i * lp_tm) * lp_n + tile_j * lp_tn;

endmodule
