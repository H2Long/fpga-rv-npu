`timescale 1ns / 1ps
// bt_buffer — 转置矩阵 BT 片上存储，64 x 32 bit
// CPU 通过 0x2000 基地址访问；每个 32 位字按四个 INT8 列元素打包。
`include "npu_defines.vh"

module bt_buffer(
    input  wire        clk,
    input  wire        we,
    input  wire [`NPU_BBUF_AW-1:0] waddr,
    input  wire [31:0] wdata,
    input  wire        re,
    input  wire [`NPU_BBUF_AW-1:0] raddr,
    output wire [31:0] rdata
);
    npu_ram #(.AW(`NPU_BBUF_AW)) u_ram(
        .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .re(re), .raddr(raddr), .rdata(rdata)
    );
endmodule
