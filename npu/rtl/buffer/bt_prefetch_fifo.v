`timescale 1ns / 1ps
// bt_prefetch_fifo — 缓存 BT RAM 返回数据。
// 它与 a_prefetch_fifo 结构相同，但保存的是 BT 通道数据。
`include "npu_defines.vh"

module bt_prefetch_fifo(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        push,
    input  wire [31:0] wdata,
    input  wire        pop,
    output wire [31:0] rdata,
    output wire        valid,
    output wire [`NPU_FIFO_AW:0] count
);
    npu_sync_fifo #(.AW(`NPU_FIFO_AW), .DW(32)) u_fifo(
        .clk(clk), .rst_n(rst_n),
        .push(push), .wdata(wdata), .pop(pop),
        .rdata(rdata), .valid(valid), .count(count)
    );
endmodule
