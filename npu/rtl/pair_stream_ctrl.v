// pair_stream_ctrl — 保证 A 和 BT 在同一拍成对进入 MAC:
//   pair_valid = a_fifo_valid && bt_fifo_valid
//   pair_fire  = feed_go && pair_valid
// 只有两侧同时有效才同时 pop,避免 K 序号错配。
`include "npu_defines.vh"

module pair_stream_ctrl(
    input  wire        feed_go,
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

    assign pair_fire = feed_go && a_fifo_valid && bt_fifo_valid;

    assign a_fifo_pop = pair_fire;
    assign bt_fifo_pop = pair_fire;

    assign a_stream_valid = pair_fire;
    assign a_stream_data  = a_fifo_rdata;
    assign bt_stream_valid = pair_fire;
    assign bt_stream_data  = bt_fifo_rdata;

endmodule
