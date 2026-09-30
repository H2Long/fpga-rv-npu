`timescale 1ns / 1ps
// a_input_unpacker — 将一拍 A 数据拆成四个 INT8 行 lane
//
// lane_en 由当前 Tile 的 valid_tm 生成；边界 Tile 中不存在的行输出 0，
// 使 PE 阵列仍能按固定 4x4 结构运行，而不会读出 Buffer 中的越界数据。
`include "npu_defines.vh"

module a_input_unpacker(
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
        // valid 描述整个 32 位字是否有效，四个 lane 共用同一个时序标志。
        lanes_valid = in_valid;
    end

endmodule
