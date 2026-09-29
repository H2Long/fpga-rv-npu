`timescale 1ns / 1ps
// c_tile_acc_ctrl — 保存一个输出 Tile 的 4x4 部分和
//
// 第一个 K tile(load_mode=1)直接装入 MAC 结果；后续 K tile 按
// c_result_index 累加。输出写回阶段通过 acc_rd_idx 组合读出一个累加值，
// 再交给 result_quantizer 量化。
`include "npu_defines.vh"

module c_tile_acc_ctrl(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        acc_tile_clear,     // 换输出 tile 时清零(保险)
    input  wire        load_mode,          // first_k_tile: 装入而非累加
    input  wire        c_result_valid,
    input  wire [3:0]  c_result_index,
    input  wire [`NPU_ACC_W-1:0] c_result,
    input  wire [3:0]  acc_rd_idx,
    output wire [`NPU_ACC_W-1:0] acc_rd_data
);

    reg [`NPU_ACC_W-1:0] acc [0:15];

    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 16; i = i + 1) acc[i] <= {`NPU_ACC_W{1'b0}};
        end else if (acc_tile_clear) begin
            for (i = 0; i < 16; i = i + 1) acc[i] <= {`NPU_ACC_W{1'b0}};
        end else if (c_result_valid) begin
            // c_result_valid 与 c_result_index 同拍有效；每拍最多更新一个 PE。
            if (load_mode)
                acc[c_result_index] <= c_result;
            else
                acc[c_result_index] <= acc[c_result_index] + c_result;
        end
    end

    assign acc_rd_data = acc[acc_rd_idx];

endmodule
