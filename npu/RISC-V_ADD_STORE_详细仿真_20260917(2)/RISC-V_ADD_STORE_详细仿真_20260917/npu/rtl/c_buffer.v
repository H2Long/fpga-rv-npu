// c_buffer — 结果矩阵片上存储,256 x 32 bit,一个 32 位字存一个 C 元素(行主序)
`include "npu_defines.vh"

module c_buffer(
    input  wire        clk,
    input  wire        we,  input  wire [`NPU_CBUF_AW-1:0] waddr, input  wire [31:0] wdata,
    input  wire        re,  input  wire [`NPU_CBUF_AW-1:0] raddr, output wire [31:0] rdata
);
    npu_ram #(.AW(`NPU_CBUF_AW)) u_ram(
        .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .re(re), .raddr(raddr), .rdata(rdata)
    );
endmodule
