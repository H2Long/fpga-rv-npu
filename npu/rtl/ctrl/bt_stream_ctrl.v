`timescale 1ns / 1ps
// bt_stream_ctrl — BT tile 读流控制:功能与 a_stream_ctrl 相同,访问转置矩阵 BT。
`include "npu_defines.vh"

module bt_stream_ctrl(
    input        clk,
    input        rst,
    input [`NPU_BBUF_AW-1:0] bt_base,
    input [`NPU_TK_W-1:0]    valid_tk,
    input        prefetch_go,
    output reg [`NPU_BBUF_AW-1:0] bt_addr,
    output reg        bt_re
);
    wire [`NPU_BBUF_AW-1:0] bt_addr_w;
    wire bt_re_w;

    npu_stream_ctrl u_stream(
        .clk(clk), .rst(rst),
        .base(bt_base), .len(valid_tk), .go(prefetch_go),
        .rd_addr(bt_addr_w), .rd_re(bt_re_w)
    );

    always @(*) begin
        bt_addr = bt_addr_w;
        bt_re = bt_re_w;
    end

endmodule
