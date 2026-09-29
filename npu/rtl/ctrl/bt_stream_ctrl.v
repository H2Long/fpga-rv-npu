`timescale 1ns / 1ps
// bt_stream_ctrl — BT tile 读流控制:功能与 a_stream_ctrl 相同,访问转置矩阵 BT。
`include "npu_defines.vh"

module bt_stream_ctrl(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [`NPU_BBUF_AW-1:0] bt_base,
    input  wire [`NPU_TK_W-1:0]    valid_tk,
    input  wire        prefetch_go,
    output wire [`NPU_BBUF_AW-1:0] bt_addr,
    output wire        bt_re
);

    npu_stream_ctrl u_stream(
        .clk(clk), .rst_n(rst_n),
        .base(bt_base), .len(valid_tk), .go(prefetch_go),
        .rd_addr(bt_addr), .rd_re(bt_re)
    );

endmodule
