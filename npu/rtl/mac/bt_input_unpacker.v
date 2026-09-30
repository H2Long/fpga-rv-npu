`timescale 1ns / 1ps
// bt_input_unpacker — 将一拍 BT 数据拆成四个 INT8 列 lane
//
// lane_en 由当前 Tile 的 valid_tn 生成；越界列补零，保证边界 Tile 不会
// 对无效列进行乘加。
`include "npu_defines.vh"

module bt_input_unpacker(
    input        in_valid,
    input [31:0] in_data,
    input [3:0]  lane_en,
    output reg [7:0]  lane0, lane1, lane2, lane3,
    output reg        lanes_valid
);

    always @(*) begin
        lane0 = lane_en[0] ? in_data[7:0]   : 8'h00;
        lane1 = lane_en[1] ? in_data[15:8]  : 8'h00;
        lane2 = lane_en[2] ? in_data[23:16] : 8'h00;
        lane3 = lane_en[3] ? in_data[31:24] : 8'h00;
        // 四个列 lane 与输入字共用同一个 valid。
        lanes_valid = in_valid;
    end

endmodule
