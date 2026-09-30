`timescale 1ns / 1ps
// drain_controller — 阵列排空计数器
//
// 最后一对输入进入后，仍需等待波前传播到最远端 PE。
// 对 P x Q 阵列，基础距离为 P+Q-2；当前 4x4 阵列为 6 个 enable 拍。
// 只在 drain_en && array_enable 时计数，阵列暂停时计数器也暂停。
`include "npu_defines.vh"

module drain_controller(
    input clk,
    input rst,
    input array_start,     // 新 tile 复位排空计数
    input drain_en,        // 排空阶段电平
    input array_enable,    // 使能拍才计数(暂停会冻结波前)
    output reg  drain_done
);

    localparam DRAIN_BEATS = `NPU_P + `NPU_Q - 2;   // 6

    reg [2:0] cnt;

    always @(posedge clk) begin
        if (rst) begin
            cnt <= 3'd0; drain_done <= 1'b0;
        end else if (array_start) begin
            cnt <= 3'd0; drain_done <= 1'b0;
        end else if (drain_en && array_enable && !drain_done) begin
            if (cnt == DRAIN_BEATS-1)
                // 本拍完成最后一次排空推进，下一拍通知 collector。
                drain_done <= 1'b1;
            else
                cnt <= cnt + 3'd1;
        end
    end

endmodule
