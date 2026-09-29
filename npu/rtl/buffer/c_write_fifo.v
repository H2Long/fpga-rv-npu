// c_write_fifo — 将 C tile 写回控制与 C RAM 写时序解耦
// 条目 = {addr[7:0], data[31:0]};每拍向 C RAM 写出一笔,写入完成产生 c_wr_pulse。
`include "npu_defines.vh"

module c_write_fifo(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        core_busy,
    // 来自 c_tile_write_ctrl
    input  wire        push,
    input  wire [`NPU_CBUF_AW-1:0] waddr,
    input  wire [31:0] wdata,
    output wire        ready,          // !full
    output wire        empty,
    // 到 c_buffer RAM
    output wire        ram_we,
    output wire [`NPU_CBUF_AW-1:0] ram_addr,
    output wire [31:0] ram_wdata,
    // 到 done_ctrl:真正写入 C RAM 的脉冲
    output wire        c_wr_pulse
);

    wire [39:0] rdata;
    wire        full;
    wire        fire = !empty && core_busy;

    npu_sync_fifo #(.AW(`NPU_FIFO_AW), .DW(40)) u_fifo(
        .clk(clk), .rst_n(rst_n),
        .push(push && !full), .wdata({waddr, wdata}), .pop(fire),
        .rdata(rdata), .valid(), .empty(empty), .full(full), .count()
    );

    assign ready      = !full;
    assign ram_we     = fire;
    assign ram_addr   = rdata[39:32];
    assign ram_wdata  = rdata[31:0];
    assign c_wr_pulse = fire;

endmodule
