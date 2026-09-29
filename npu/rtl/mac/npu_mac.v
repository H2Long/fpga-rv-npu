// npu_mac — 计算平面。
//
// 输入路径把一个 32 位字拆为 4 个 INT8，再用 skew 管线让不同的行/列
// 在正确的周期相遇。PE 阵列只在 array_enable 时推进；排空阶段没有新输入，
// 但仍保持 enable，让最后一个波前到达远端 PE。
`include "npu_defines.vh"

module npu_mac(
    input  wire        clk,
    input  wire        rst_n,
    // 阵列控制(来自 npu_ctrl.array_ctrl)
    input  wire        array_start,
    input  wire        array_enable,
    input  wire        array_clear_acc,
    input  wire        array_flush,
    // A/BT 输入流(来自 npu_ctrl.pair_stream_ctrl)
    input  wire        a_stream_valid,
    input  wire [31:0] a_stream_data,
    input  wire        bt_stream_valid,
    input  wire [31:0] bt_stream_data,
    input  wire [3:0]  a_lane_en,
    input  wire [3:0]  bt_lane_en,
    // 流握手
    output wire        a_stream_ready,
    output wire        bt_stream_ready,
    // 状态(到 npu_ctrl)
    output wire        array_done,
    // C 结果流(到 npu_ctrl.c_tile_acc_ctrl)
    output wire        c_result_valid,
    output wire [`NPU_ACC_W-1:0] c_result,
    output wire [3:0]  c_result_index
);

    // ---- 输入拆包 ----
    wire [7:0] a_l0, a_l1, a_l2, a_l3;   wire a_lv;
    wire [7:0] b_l0, b_l1, b_l2, b_l3;   wire b_lv;

    a_input_unpacker u_a_input_unpacker(
        .in_valid(a_stream_valid), .in_data(a_stream_data), .lane_en(a_lane_en),
        .lane0(a_l0), .lane1(a_l1), .lane2(a_l2), .lane3(a_l3),
        .lanes_valid(a_lv)
    );

    bt_input_unpacker u_bt_input_unpacker(
        .in_valid(bt_stream_valid), .in_data(bt_stream_data), .lane_en(bt_lane_en),
        .lane0(b_l0), .lane1(b_l1), .lane2(b_l2), .lane3(b_l3),
        .lanes_valid(b_lv)
    );

    // ---- 波前对齐 ----
    wire [7:0] a_sk0, a_sk1, a_sk2, a_sk3;   wire a_sk_v0, a_sk_v1, a_sk_v2, a_sk_v3;
    wire [7:0] bt_sk0, bt_sk1, bt_sk2, bt_sk3; wire bt_sk_v0, bt_sk_v1, bt_sk_v2, bt_sk_v3;

    a_bt_skew_pipeline u_skew(
        .clk(clk), .rst_n(rst_n), .enable(array_enable),
        .a_in0(a_l0), .a_in1(a_l1), .a_in2(a_l2), .a_in3(a_l3), .a_in_v(a_lv),
        .bt_in0(b_l0), .bt_in1(b_l1), .bt_in2(b_l2), .bt_in3(b_l3), .bt_in_v(b_lv),
        .a_sk0(a_sk0), .a_sk1(a_sk1), .a_sk2(a_sk2), .a_sk3(a_sk3),
        .a_sk_v0(a_sk_v0), .a_sk_v1(a_sk_v1), .a_sk_v2(a_sk_v2), .a_sk_v3(a_sk_v3),
        .bt_sk0(bt_sk0), .bt_sk1(bt_sk1), .bt_sk2(bt_sk2), .bt_sk3(bt_sk3),
        .bt_sk_v0(bt_sk_v0), .bt_sk_v1(bt_sk_v1), .bt_sk_v2(bt_sk_v2), .bt_sk_v3(bt_sk_v3)
    );

    // ---- PE 阵列 ----
    wire [16*`NPU_ACC_W-1:0] acc_flat;

    pe_array u_pe_array(
        .clk(clk), .rst_n(rst_n), .enable(array_enable), .clear_acc(array_clear_acc),
        .a_lanes({a_sk3, a_sk2, a_sk1, a_sk0}),
        .a_lane_v({a_sk_v3, a_sk_v2, a_sk_v1, a_sk_v0}),
        .bt_lanes({bt_sk3, bt_sk2, bt_sk1, bt_sk0}),
        .bt_lane_v({bt_sk_v3, bt_sk_v2, bt_sk_v1, bt_sk_v0}),
        .acc_flat(acc_flat)
    );

    // ---- 排空与收集 ----
    // drain_done 只代表波前已经传播到最远端，collector 还要再串行输出 16 个结果。
    wire drain_done, collect_done;

    drain_controller u_drain_controller(
        .clk(clk), .rst_n(rst_n),
        .array_start(array_start), .array_flush(array_flush), .array_enable(array_enable),
        .drain_done(drain_done)
    );

    wire [3:0] scan_index;

    tile_result_collector u_tile_result_collector(
        .clk(clk), .rst_n(rst_n),
        .array_start(array_start), .drain_done_i(drain_done), .acc_flat(acc_flat),
        .c_result_valid(c_result_valid), .c_result(c_result),
        .c_scan_index(scan_index),
        .collect_done(collect_done)
    );

    output_reorder u_output_reorder(
        .scan_index(scan_index), .c_result_index(c_result_index)
    );

    // ---- 状态 ----
    mac_status u_mac_status(
        .clk(clk), .rst_n(rst_n),
        .collect_done(collect_done),
        .array_done(array_done)
    );

    // 当前阵列没有额外的随机反压：feed 和 drain 期间都可以推进。
    assign a_stream_ready  = array_enable;
    assign bt_stream_ready = array_enable;

endmodule
