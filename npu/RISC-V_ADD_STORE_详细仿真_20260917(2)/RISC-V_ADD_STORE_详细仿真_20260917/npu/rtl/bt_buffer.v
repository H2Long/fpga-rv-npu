// bt_buffer — 转置矩阵 BT 片上存储,64 x 32 bit(N x K 行主序,k 主序打包)
`include "npu_defines.vh"

module bt_buffer(
    input  wire        clk,
    input  wire        we,  input  wire [`NPU_BBUF_AW-1:0] waddr, input  wire [31:0] wdata,
    input  wire        re,  input  wire [`NPU_BBUF_AW-1:0] raddr, output wire [31:0] rdata
);
    npu_ram #(.AW(`NPU_BBUF_AW)) u_ram(
        .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .re(re), .raddr(raddr), .rdata(rdata)
    );
endmodule
