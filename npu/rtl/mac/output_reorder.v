`timescale 1ns / 1ps
// output_reorder — 将 PE 物理坐标转换为 C Tile 行主序下标
// scan_index={row[1:0],col[1:0]}，输出 row*Q+col。
// 当前 collector 本身按行主序扫描，因此结果是恒等映射；保留独立模块
// 是为了把“物理 PE 编号”和“C 矩阵逻辑编号”边界明确隔开。
`include "npu_defines.vh"

module output_reorder(
    input  wire [3:0] scan_index,     // {row[1:0], col[1:0]}
    output wire [3:0] c_result_index  // row*Q + col
);

    wire [1:0] row = scan_index[3:2];
    wire [1:0] col = scan_index[1:0];

    assign c_result_index = row * `NPU_Q + col;

endmodule
