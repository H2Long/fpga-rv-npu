// output_reorder — 将 PE 物理坐标转换为 C tile 行主序下标:
//   c_result_index = row * Q + column
// 收集器按行主序扫描时该映射为恒等,保留此级以显式承载坐标语义。
`include "npu_defines.vh"

module output_reorder(
    input  wire [3:0] scan_index,     // {row[1:0], col[1:0]}
    output wire [3:0] c_result_index  // row*Q + col
);

    wire [1:0] row = scan_index[3:2];
    wire [1:0] col = scan_index[1:0];

    assign c_result_index = row * `NPU_Q + col;

endmodule
