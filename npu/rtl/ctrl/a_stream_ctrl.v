`timescale 1ns / 1ps
// a_stream_ctrl — A tile 读流控制:根据 A tile 字基地址发起 RAM 读,
// 处理按 valid_tk 截断的边界(越界 k 不读取)。
`include "npu_defines.vh"

module a_stream_ctrl(
    input        clk,
    input        rst,
    input [`NPU_ABUF_AW-1:0] a_base,
    input [`NPU_TK_W-1:0]    valid_tk,
    input        prefetch_go,
    output reg [`NPU_ABUF_AW-1:0] a_addr,
    output reg        a_re
);
    wire [`NPU_ABUF_AW-1:0] a_addr_w;
    wire a_re_w;

    npu_stream_ctrl u_stream(
        .clk(clk), .rst(rst),
        .base(a_base), .len(valid_tk), .go(prefetch_go),
        .rd_addr(a_addr_w), .rd_re(a_re_w)
    );

    always @(*) begin
        a_addr = a_addr_w;
        a_re = a_re_w;
    end

endmodule
