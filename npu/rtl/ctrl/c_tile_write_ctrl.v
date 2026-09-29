`timescale 1ns / 1ps
// c_tile_write_ctrl — 输出 Tile 写回控制
//
// 每拍扫描一个物理 lane：
//   1. acc_rd_idx 选择一个 PE 累加器；
//   2. result_quantizer 组合地产生 quant_word；
//   3. 有效 lane 且 FIFO 不满时产生 cwr_valid，并推进 idx。
// 边界 Tile 中 r>=valid_tm 或 c>=valid_tn 的 lane 不写回，但 idx 仍跳过。
// idx=16 表示 16 个物理 lane 已扫描完；write_done 还要等待 cwr_empty，
// 确保最后一项已经真正写入 C RAM。
`include "npu_defines.vh"

module c_tile_write_ctrl(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        write_go,
    input  wire [`NPU_CBASE_W-1:0] c_base,    // tile_i*TM*N + tile_j*TN(元素地址)
    input  wire [`NPU_DIM_W-1:0]  n_dim,
    input  wire [`NPU_TILE_W-1:0] valid_tm, valid_tn,
    // 累加器索引与量化结果(result_quantizer)
    output wire [3:0]  acc_rd_idx,
    input  wire [31:0] quant_word,
    // 到 c_write_fifo
    output wire        cwr_valid,
    output wire [`NPU_CBUF_AW-1:0] cwr_addr,
    output wire [31:0] cwr_data,
    input  wire        cwr_ready,             // FIFO 未满
    input  wire        cwr_empty,             // FIFO 已排空
    // 状态
    output wire        write_done
);

    reg [4:0] idx;        // 0..15 扫描,16 表示扫描完成

    wire [1:0] r = idx[3:2];
    wire [1:0] c = idx[1:0];
    wire       lane_ok = (idx < 5'd16) &&
                         ({1'b0, r} < valid_tm) && ({1'b0, c} < valid_tn);

    // 组合推进：有效 lane 且 FIFO 有空间时入队并前进；无效 lane 直接跳过。
    wire advance = (idx < 5'd16) && (lane_ok ? cwr_ready : 1'b1);

    assign acc_rd_idx = idx[3:0];             // 组合直出,与 r/c 同源
    // cwr_valid 与 cwr_ready 相与，表示本拍一定能完成一次 FIFO 入队。
    assign cwr_valid  = write_go && lane_ok && cwr_ready;
    wire [`NPU_CBASE_W+1:0] c_addr_full = c_base + r * n_dim + c;
    assign cwr_addr   = c_addr_full[`NPU_CBUF_AW-1:0];
    assign cwr_data   = quant_word;
    assign write_done = write_go && (idx >= 5'd16) && cwr_empty;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idx <= 5'd0;
        end else if (!write_go) begin
            idx <= 5'd0;
        end else if (advance) begin
            idx <= idx + 5'd1;
        end
    end

endmodule
