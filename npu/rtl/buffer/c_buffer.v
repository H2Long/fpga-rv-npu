`timescale 1ns / 1ps
// c_buffer — 结果矩阵片上存储，256 x 32 bit
// 一个 32 位字存放一个量化后的 C 元素，地址按 C 矩阵行主序递增。
`include "npu_defines.vh"

module c_buffer(
    input        clk,
    input        we,
    input [`NPU_CBUF_AW-1:0] waddr,
    input [31:0] wdata,
    input        re,
    input [`NPU_CBUF_AW-1:0] raddr,
    output reg [31:0] rdata
);
    wire [31:0] rdata_w;

    npu_ram #(.AW(`NPU_CBUF_AW)) u_ram(
        .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .re(re), .raddr(raddr), .rdata(rdata_w)
    );

    always @(*) begin
        rdata = rdata_w;
    end
endmodule
