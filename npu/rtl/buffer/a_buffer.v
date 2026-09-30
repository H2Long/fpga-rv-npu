`timescale 1ns / 1ps
// a_buffer — A 矩阵片上存储，64 x 32 bit
// CPU 地址 0x1000 已由 addr_decoder 转成这里使用的字地址。
// 一个字的布局(k 主序,行进字节):
//   [7:0]  = A[base+0][k]  [15:8] = A[base+1][k]
//   [23:16]= A[base+2][k]  [31:24]= A[base+3][k]
`include "npu_defines.vh"

module a_buffer(
    input        clk,
    input        we,
    input [`NPU_ABUF_AW-1:0] waddr,
    input [31:0] wdata,
    input        re,
    input [`NPU_ABUF_AW-1:0] raddr,
    output reg [31:0] rdata
);
    wire [31:0] rdata_w;

    npu_ram #(.AW(`NPU_ABUF_AW)) u_ram(
        .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .re(re), .raddr(raddr), .rdata(rdata_w)
    );

    always @(*) begin
        rdata = rdata_w;
    end
endmodule
