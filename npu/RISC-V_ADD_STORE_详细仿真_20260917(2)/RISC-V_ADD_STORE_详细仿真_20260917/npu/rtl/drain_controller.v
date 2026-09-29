// drain_controller — 最后一对输入进入后,等待波前传播到阵列最远端:
// 基础排空距离 P+Q-2 = 6 个使能拍(此后 PE[3][3] 的最后一次乘加已锁存)。
`include "npu_defines.vh"

module drain_controller(
    input  wire clk,
    input  wire rst_n,
    input  wire array_start,     // 新 tile 复位排空计数
    input  wire array_flush,     // 排空阶段电平
    input  wire array_enable,    // 使能拍才计数(暂停会冻结波前)
    output reg  drain_done
);

    localparam DRAIN_BEATS = `NPU_P + `NPU_Q - 2;   // 6

    reg [2:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= 3'd0; drain_done <= 1'b0;
        end else if (array_start) begin
            cnt <= 3'd0; drain_done <= 1'b0;
        end else if (array_flush && array_enable && !drain_done) begin
            if (cnt == DRAIN_BEATS-1)
                drain_done <= 1'b1;
            else
                cnt <= cnt + 3'd1;
        end
    end

endmodule
