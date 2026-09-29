// pe_cell — 单个处理单元:本拍输入组合乘加,寄存器向右/向下转发
//   有效周期: acc += signed(a_in) * signed(bt_in)
//   a_out/bt_out 为寄存转发(各 1 拍传播延迟)
`include "npu_defines.vh"

module pe_cell(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire        clear_acc,
    input  wire [7:0]  a_in,
    input  wire        a_v_in,
    input  wire [7:0]  bt_in,
    input  wire        bt_v_in,
    output reg  [7:0]  a_out,
    output reg         a_v_out,
    output reg  [7:0]  bt_out,
    output reg         bt_v_out,
    output reg  [`NPU_ACC_W-1:0] acc
);

    wire signed [`NPU_ACC_W-1:0] prod_ext =
        $signed(a_in) * $signed(bt_in);   // INT8 x INT8, 符号扩展进 32 位

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out <= 8'd0; a_v_out <= 1'b0;
            bt_out <= 8'd0; bt_v_out <= 1'b0;
            acc <= {`NPU_ACC_W{1'b0}};
        end else if (clear_acc) begin
            a_v_out <= 1'b0; bt_v_out <= 1'b0;   // 冲刷残留波前
            a_out <= 8'd0;  bt_out <= 8'd0;
            acc <= {`NPU_ACC_W{1'b0}};
        end else if (enable) begin
            a_out <= a_in;   a_v_out <= a_v_in;
            bt_out <= bt_in; bt_v_out <= bt_v_in;
            if (a_v_in && bt_v_in)
                acc <= acc + prod_ext;
        end
    end

endmodule
