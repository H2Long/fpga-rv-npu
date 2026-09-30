`timescale 1ns / 1ps
// pair_stream_ctrl — 保证 A 和 BT 在同一拍成对进入 MAC。
//
// FIFO count 非零表示数据已经在队头稳定；只有 feed_go 且两侧都有数据时，
// 才允许两边一起 pop，保证 A、BT 的 K 序号不发生错位。
`include "npu_defines.vh"

module pair_stream_ctrl(
    input        feed_go,
    input [31:0] a_fifo_rdata,
    input [`NPU_FIFO_AW:0] a_fifo_count,
    input [31:0] bt_fifo_rdata,
    input [`NPU_FIFO_AW:0] bt_fifo_count,
    output reg        pair_fire,
    output reg        a_fifo_pop,
    output reg        bt_fifo_pop,
    output reg [31:0] a_stream_data,
    output reg [31:0] bt_stream_data,
    output reg        stream_valid
);

    // pair_fire 是唯一的“成对消费”事件：
    //   - 它同时弹出 A/BT 两侧 FIFO；
    //   - 它同时拉高成对的 stream_valid；
    //   - 因此两个矩阵的 K 序号永远保持一致。
    always @(*) begin
        pair_fire = feed_go && (a_fifo_count != 0) && (bt_fifo_count != 0);
        a_fifo_pop = pair_fire;
        bt_fifo_pop = pair_fire;
        a_stream_data  = a_fifo_rdata;
        bt_stream_data  = bt_fifo_rdata;
        stream_valid = pair_fire;
    end

endmodule
