// a_input_unpacker — 将一拍 A 数据(32 位字)拆成 P=4 个有符号 INT8 行 lane,
// 越界 lane(lane_en=0)补零。
`include "npu_defines.vh"

module a_input_unpacker(
    input  wire        in_valid,
    input  wire [31:0] in_data,
    input  wire [3:0]  lane_en,
    output wire [7:0]  lane0, lane1, lane2, lane3,
    output wire        lanes_valid
);

    assign lane0 = lane_en[0] ? in_data[7:0]   : 8'h00;
    assign lane1 = lane_en[1] ? in_data[15:8]  : 8'h00;
    assign lane2 = lane_en[2] ? in_data[23:16] : 8'h00;
    assign lane3 = lane_en[3] ? in_data[31:24] : 8'h00;
    assign lanes_valid = in_valid;

endmodule
