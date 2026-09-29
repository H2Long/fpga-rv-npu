// tile_result_collector — 排空完成后串行输出 16 个 PE 累加结果(每拍一个),
// 全部输出后产生单拍 collect_done。
`include "npu_defines.vh"

module tile_result_collector(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        array_start,       // 新 tile 复位
    input  wire        drain_done_i,
    input  wire [16*`NPU_ACC_W-1:0] acc_flat,
    output reg         c_result_valid,
    output reg  [`NPU_ACC_W-1:0] c_result,
    output reg  [3:0]  c_scan_index,      // 原始扫描下标(行主序)
    output reg         c_result_last,
    output reg         collect_done       // 单拍,16 个结果已全部送出
);

    localparam C_IDLE = 2'd0, C_STREAM = 2'd1, C_PULSE = 2'd2, C_HOLD = 2'd3;
    reg [1:0] state;
    reg [3:0] idx;

    // drain_done 后从 PE[0][0] 到 PE[3][3] 逐拍输出 16 个累加器。
    // c_result_last 与最后一个结果同拍，collect_done 再延后一拍通知 MAC 状态机。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= C_IDLE; idx <= 4'd0;
            c_result_valid <= 1'b0; c_result <= {`NPU_ACC_W{1'b0}};
            c_scan_index <= 4'd0; c_result_last <= 1'b0; collect_done <= 1'b0;
        end else begin
            c_result_valid <= 1'b0;
            c_result_last  <= 1'b0;
            collect_done   <= 1'b0;
            case (state)
                C_IDLE: begin
                    if (drain_done_i) begin
                        idx <= 4'd0; state <= C_STREAM;
                    end
                end
                C_STREAM: begin
                    c_result_valid <= 1'b1;
                    c_result       <= acc_flat[idx*`NPU_ACC_W +: `NPU_ACC_W];
                    c_scan_index   <= idx;
                    if (idx == 4'd15) begin
                        c_result_last <= 1'b1;
                        state <= C_PULSE;
                    end
                    idx <= idx + 4'd1;
                end
                C_PULSE: begin
                    collect_done <= 1'b1;
                    state <= C_HOLD;      // 保持直到下一个 array_start
                end
                C_HOLD: begin
                    if (array_start) state <= C_IDLE;
                end
                default: state <= C_IDLE;
            endcase
        end
    end

endmodule
