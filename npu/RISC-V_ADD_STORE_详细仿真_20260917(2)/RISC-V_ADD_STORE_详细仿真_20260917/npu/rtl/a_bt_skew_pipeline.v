// a_bt_skew_pipeline — 脉动波前对齐:
//   A 行 r 延迟 r 拍,BT 列 c 延迟 c 拍(data 与 valid 同步延迟)
// 使 A[r][k] 与 BT[c][k] 恰好在 PE[r][c] 的输入端同一拍到达。
// 整个管线受 array_enable 门控,阵列暂停时保持。
`include "npu_defines.vh"

module a_bt_skew_pipeline(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    // A 侧输入(a_input_unpacker)
    input  wire [7:0]  a_in0, a_in1, a_in2, a_in3,
    input  wire        a_in_v,
    // BT 侧输入(bt_input_unpacker)
    input  wire [7:0]  bt_in0, bt_in1, bt_in2, bt_in3,
    input  wire        bt_in_v,
    // A 侧输出(到 pe_array 各行最左)
    output wire [7:0]  a_sk0, a_sk1, a_sk2, a_sk3,
    output wire        a_sk_v0, a_sk_v1, a_sk_v2, a_sk_v3,
    // BT 侧输出(到 pe_array 各列最上)
    output wire [7:0]  bt_sk0, bt_sk1, bt_sk2, bt_sk3,
    output wire        bt_sk_v0, bt_sk_v1, bt_sk_v2, bt_sk_v3
);

    // A lane1: 1 级延迟
    reg [7:0] a1_r;  reg a1_v;
    // A lane2: 2 级延迟
    reg [7:0] a2_r0, a2_r1;  reg a2_v0, a2_v1;
    // A lane3: 3 级延迟
    reg [7:0] a3_r0, a3_r1, a3_r2;  reg a3_v0, a3_v1, a3_v2;

    // BT 同构
    reg [7:0] b1_r;  reg b1_v;
    reg [7:0] b2_r0, b2_r1;  reg b2_v0, b2_v1;
    reg [7:0] b3_r0, b3_r1, b3_r2;  reg b3_v0, b3_v1, b3_v2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a1_r <= 8'd0; a1_v <= 1'b0;
            a2_r0 <= 8'd0; a2_r1 <= 8'd0; a2_v0 <= 1'b0; a2_v1 <= 1'b0;
            a3_r0 <= 8'd0; a3_r1 <= 8'd0; a3_r2 <= 8'd0;
            a3_v0 <= 1'b0; a3_v1 <= 1'b0; a3_v2 <= 1'b0;
            b1_r <= 8'd0; b1_v <= 1'b0;
            b2_r0 <= 8'd0; b2_r1 <= 8'd0; b2_v0 <= 1'b0; b2_v1 <= 1'b0;
            b3_r0 <= 8'd0; b3_r1 <= 8'd0; b3_r2 <= 8'd0;
            b3_v0 <= 1'b0; b3_v1 <= 1'b0; b3_v2 <= 1'b0;
        end else if (enable) begin
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

    assign a_sk0  = a_in0;   assign a_sk_v0 = a_in_v;
    assign a_sk1  = a1_r;    assign a_sk_v1 = a1_v;
    assign a_sk2  = a2_r1;   assign a_sk_v2 = a2_v1;
    assign a_sk3  = a3_r2;   assign a_sk_v3 = a3_v2;

    assign bt_sk0  = bt_in0; assign bt_sk_v0 = bt_in_v;
    assign bt_sk1  = b1_r;   assign bt_sk_v1 = b1_v;
    assign bt_sk2  = b2_r1;  assign bt_sk_v2 = b2_v1;
    assign bt_sk3  = b3_r2;  assign bt_sk_v3 = b3_v2;

endmodule
