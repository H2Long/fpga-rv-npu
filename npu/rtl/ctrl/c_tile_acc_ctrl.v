// c_tile_acc_ctrl — 保存 P*Q 个 ACC_W 位累加值(一个完整 C tile)
// 第一个 K tile(load_mode=1)装入;后续 K tile 按 c_result_index 累加。
// WRITE_C_TILE 阶段按 acc_rd_idx 串行读出。
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
            if (load_mode)
                acc[c_result_index] <= c_result;
            else
                acc[c_result_index] <= acc[c_result_index] + c_result;
        end
    end

    assign acc_rd_data = acc[acc_rd_idx];

endmodule
