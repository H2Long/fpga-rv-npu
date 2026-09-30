`timescale 1ns / 1ps
// c_write_fifo — 解耦 C tile 写回控制与 C RAM 写时序
//
// FIFO 每个条目为 {C 地址, C 数据}。c_tile_write_ctrl 只负责把结果入队；
// 本模块在 C RAM 可用且 FIFO 非空时每拍弹出一项。
// fire 同时驱动 ram_we 和 c_wr_pulse，因此 c_wr_pulse 表示“已经真正写 RAM”，
// done_ctrl 必须使用它统计完成，不能只统计 FIFO 入队数。
`include "npu_defines.vh"

module c_write_fifo(
    input        clk,
    input        rst,
    input        core_busy,
    // 来自 c_tile_write_ctrl
    input        push,
    input [`NPU_CBUF_AW-1:0] waddr,
    input [31:0] wdata,
    output reg        ready,          // !full
    output reg        empty,
    // 到 c_buffer RAM
    output reg        ram_we,
    output reg [`NPU_CBUF_AW-1:0] ram_addr,
    output reg [31:0] ram_wdata,
    // 到 done_ctrl:真正写入 C RAM 的脉冲
    output reg        c_wr_pulse
);

    wire [39:0] rdata;
    wire        full;
    wire        empty_w;
    reg         fire;

    npu_sync_fifo #(.AW(`NPU_FIFO_AW), .DW(40)) u_fifo(
        .clk(clk), .rst(rst),
        .push(push && !full), .wdata({waddr, wdata}), .pop(fire),
        .rdata(rdata), .valid(), .empty(empty_w), .full(full), .count()
    );

    always @(*) begin
        fire       = !empty_w && core_busy;
        ready      = !full;
        empty      = empty_w;
        ram_we     = fire;
        ram_addr   = rdata[39:32];
        ram_wdata  = rdata[31:0];
        c_wr_pulse = fire;
    end

endmodule
