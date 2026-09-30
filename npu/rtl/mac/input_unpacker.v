`timescale 1ns / 1ps
// input_unpacker — 将一个 32 位字拆成四个带边界屏蔽的 INT8 lane。
// A 和 BT 的拆包规则相同，行/列语义由调用方决定。
`include "npu_defines.vh"

module input_unpacker(
    input        in_valid,
    input [31:0] in_data,
    input [3:0]  lane_en,
    output reg [7:0] lane0, lane1, lane2, lane3,
    output reg       lanes_valid
);

    always @(*) begin
        lane0 = lane_en[0] ? in_data[7:0]   : 8'h00;
        lane1 = lane_en[1] ? in_data[15:8]  : 8'h00;
        lane2 = lane_en[2] ? in_data[23:16] : 8'h00;
        lane3 = lane_en[3] ? in_data[31:24] : 8'h00;
        lanes_valid = in_valid;
    end

endmodule
