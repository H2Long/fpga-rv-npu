// npu_ram — 通用同步 RAM:一个写端口 + 一个同步读端口(读数据下一拍有效)
`include "npu_defines.vh"

module npu_ram #(parameter AW = 6) (
    input  wire        clk,
    input  wire        we,
    input  wire [AW-1:0] waddr,
    input  wire [31:0] wdata,
    input  wire        re,
    input  wire [AW-1:0] raddr,
    output reg  [31:0] rdata
);

    reg [31:0] mem [0:(1<<AW)-1];
    integer i;

    initial begin
        for (i = 0; i < (1<<AW); i = i + 1) mem[i] = 32'd0;
        rdata = 32'd0;
    end

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end

endmodule
