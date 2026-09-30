`timescale 1ns / 1ps
// a_bt_skew_pipeline — 脉动阵列输入波前对齐
//
// A 的第 r 行延迟 r 拍，BT 的第 c 列延迟 c 拍，且 data 与 valid 使用
// 完全相同的寄存器级数。这样 A[r][k] 与 BT[c][k] 才会在 PE[r][c]
// 的输入端同一拍到达。array_enable=0 时所有级保持，暂停不会丢失波前。
`include "npu_defines.vh"

module a_bt_skew_pipeline(
    input        clk,
    input        rst,
    input        enable,
    // A 侧输入(a_input_unpacker)
    input [7:0]  a_in0, a_in1, a_in2, a_in3,
    input        a_in_v,
    // BT 侧输入(bt_input_unpacker)
    input [7:0]  bt_in0, bt_in1, bt_in2, bt_in3,
    input        bt_in_v,
    // A 侧输出(到 pe_array 各行最左)
    output reg [7:0]  a_sk0, a_sk1, a_sk2, a_sk3,
    output reg        a_sk_v0, a_sk_v1, a_sk_v2, a_sk_v3,
    // BT 侧输出(到 pe_array 各列最上)
    output reg [7:0]  bt_sk0, bt_sk1, bt_sk2, bt_sk3,
    output reg        bt_sk_v0, bt_sk_v1, bt_sk_v2, bt_sk_v3
);

    // A lane1：1 级延迟；lane0 直接旁路。
    reg [7:0] a1_r;  reg a1_v;
    // A lane2: 2 级延迟
    reg [7:0] a2_r0, a2_r1;  reg a2_v0, a2_v1;
    // A lane3: 3 级延迟
    reg [7:0] a3_r0, a3_r1, a3_r2;  reg a3_v0, a3_v1, a3_v2;

    // BT 侧结构同构：lane1/2/3 分别延迟 1/2/3 拍。
    reg [7:0] b1_r;  reg b1_v;
    reg [7:0] b2_r0, b2_r1;  reg b2_v0, b2_v1;
    reg [7:0] b3_r0, b3_r1, b3_r2;  reg b3_v0, b3_v1, b3_v2;

    always @(posedge clk) begin
        if (rst) begin
            a1_r <= 8'd0; a1_v <= 1'b0;
            a2_r0 <= 8'd0; a2_r1 <= 8'd0; a2_v0 <= 1'b0; a2_v1 <= 1'b0;
            a3_r0 <= 8'd0; a3_r1 <= 8'd0; a3_r2 <= 8'd0;
            a3_v0 <= 1'b0; a3_v1 <= 1'b0; a3_v2 <= 1'b0;
            b1_r <= 8'd0; b1_v <= 1'b0;
            b2_r0 <= 8'd0; b2_r1 <= 8'd0; b2_v0 <= 1'b0; b2_v1 <= 1'b0;
            b3_r0 <= 8'd0; b3_r1 <= 8'd0; b3_r2 <= 8'd0;
            b3_v0 <= 1'b0; b3_v1 <= 1'b0; b3_v2 <= 1'b0;
        end else if (enable) begin
            // 每一级同时寄存数据和 valid，不能只延迟数据，否则无效数据会被 PE 累加。
            // A lane1
            a1_r <= a_in1; a1_v <= a_in_v;
            // A lane2
            a2_r0 <= a_in2;  a2_r1 <= a2_r0;
            a2_v0 <= a_in_v; a2_v1 <= a2_v0;
            // A lane3
            a3_r0 <= a_in3;  a3_r1 <= a3_r0;  a3_r2 <= a3_r1;
            a3_v0 <= a_in_v; a3_v1 <= a3_v0;  a3_v2 <= a3_v1;
            // BT lane1
            b1_r <= bt_in1; b1_v <= bt_in_v;
            // BT lane2
            b2_r0 <= bt_in2;  b2_r1 <= b2_r0;
            b2_v0 <= bt_in_v; b2_v1 <= b2_v0;
            // BT lane3
            b3_r0 <= bt_in3;  b3_r1 <= b3_r0;  b3_r2 <= b3_r1;
            b3_v0 <= bt_in_v; b3_v1 <= b3_v0;  b3_v2 <= b3_v1;
        end
    end

    always @(*) begin
        a_sk0  = a_in0;   a_sk_v0 = a_in_v;
        a_sk1  = a1_r;    a_sk_v1 = a1_v;
        a_sk2  = a2_r1;   a_sk_v2 = a2_v1;
        a_sk3  = a3_r2;   a_sk_v3 = a3_v2;
        bt_sk0  = bt_in0; bt_sk_v0 = bt_in_v;
        bt_sk1  = b1_r;   bt_sk_v1 = b1_v;
        bt_sk2  = b2_r1;  bt_sk_v2 = b2_v1;
        bt_sk3  = b3_r2;  bt_sk_v3 = b3_v2;
    end

endmodule
