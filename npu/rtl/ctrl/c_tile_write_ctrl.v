// c_tile_write_ctrl — 按 tile 内 (r,c) 串行读出累加器 -> 量化 -> 生成 C 字地址 ->
// 写入 c_write_fifo。越界 lane(r>=valid_tm 或 c>=valid_tn)不写回。
// write_done 在全部条目入队且 FIFO 排空后置位(core_done 的前提)。
// 累加器读出与量化均为组合链:acc[acc_rd_idx] -> result_quantizer -> cwr_data。
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

    // 组合推进:有效 lane 且 FIFO 有空间时入队并前进;无效 lane 直接跳过
    wire advance = (idx < 5'd16) && (lane_ok ? cwr_ready : 1'b1);

    assign acc_rd_idx = idx[3:0];             // 组合直出,与 r/c 同源
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
