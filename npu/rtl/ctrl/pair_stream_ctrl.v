`timescale 1ns / 1ps
// pair_stream_ctrl — 保证 A 和 BT 在同一拍成对进入 MAC。
//
// FIFO 的 valid 表示数据已经在队头稳定，MAC 的 ready 表示本拍能够接收。
// 只有 feed_go、两侧 valid 和两侧 ready 同时成立，才允许两边一起 pop。
// 这样即使将来 MAC 增加反压，也不会让 A、BT 的 K 序号发生错位。
`include "npu_defines.vh"

module pair_stream_ctrl(
    input  wire        feed_go,
    input  wire        a_stream_ready,
    input  wire        bt_stream_ready,
    input  wire        a_fifo_valid,
    input  wire [31:0] a_fifo_rdata,
    input  wire        bt_fifo_valid,
    input  wire [31:0] bt_fifo_rdata,
    output wire        pair_fire,
    output wire        a_fifo_pop,
    output wire        bt_fifo_pop,
    output wire        a_stream_valid,
    output wire [31:0] a_stream_data,
    output wire        bt_stream_valid,
    output wire [31:0] bt_stream_data
);

    // pair_fire 是唯一的“成对消费”事件：
    //   - 它同时弹出 A/BT 两侧 FIFO；
    //   - 它同时拉高两个 stream_valid；
    //   - 因此两个矩阵的 K 序号永远保持一致。
    assign pair_fire = feed_go && a_stream_ready && bt_stream_ready &&
                       a_fifo_valid && bt_fifo_valid;

    assign a_fifo_pop = pair_fire;
    assign bt_fifo_pop = pair_fire;

    assign a_stream_valid = pair_fire;
    assign a_stream_data  = a_fifo_rdata;
    assign bt_stream_valid = pair_fire;
    assign bt_stream_data  = bt_fifo_rdata;

endmodule
