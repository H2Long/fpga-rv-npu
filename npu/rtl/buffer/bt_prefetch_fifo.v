`timescale 1ns / 1ps
// bt_prefetch_fifo — 缓存 BT RAM 返回数据。
// 它与 a_prefetch_fifo 结构相同，但保存的是 BT 通道数据。
`include "npu_defines.vh"

module bt_prefetch_fifo(
    input        clk,
    input        rst,
    input        push,
    input [31:0] wdata,
    input        pop,
    output reg [31:0] rdata,
    output reg        valid,
    output reg [`NPU_FIFO_AW:0] count
);
    wire [31:0] rdata_w;
    wire        valid_w;
    wire [`NPU_FIFO_AW:0] count_w;

    npu_sync_fifo #(.AW(`NPU_FIFO_AW), .DW(32)) u_fifo(
        .clk(clk), .rst(rst),
        .push(push), .wdata(wdata), .pop(pop),
        .rdata(rdata_w), .valid(valid_w), .count(count_w)
    );

    always @(*) begin
        rdata = rdata_w;
        valid = valid_w;
        count = count_w;
    end
endmodule
