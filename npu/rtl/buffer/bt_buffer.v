`timescale 1ns / 1ps
// bt_buffer — 转置矩阵 BT 片上存储，64 x 32 bit
// CPU 通过 0x2000 基地址访问；每个 32 位字按四个 INT8 列元素打包。
`include "npu_defines.vh"

module bt_buffer(
    input        clk,
    input        we,
    input [`NPU_BBUF_AW-1:0] waddr,
    input [31:0] wdata,
    input        re,
    input [`NPU_BBUF_AW-1:0] raddr,
    output reg [31:0] rdata
);
    wire [31:0] rdata_w;

    npu_ram #(.AW(`NPU_BBUF_AW)) u_ram(
        .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .re(re), .raddr(raddr), .rdata(rdata_w)
    );

    always @(*) begin
        rdata = rdata_w;
    end
endmodule
