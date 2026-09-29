`timescale 1ns / 1ps
// mac_status — 汇总一个 MAC Tile 的完成状态
// collect_done 是 collector 的完成脉冲；本模块将其原样打一拍输出
// array_done，供 systolic_fsm 从 RECEIVE_RESULT 状态离开。
`include "npu_defines.vh"

module mac_status(
    input  wire clk,
    input  wire rst_n,
    input  wire collect_done,     // 16 个结果全部送出
    output reg  array_done        // 单拍:本次 tile 结果流结束
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            array_done <= 1'b0;
        end else begin
            // array_done 是单拍脉冲，不能保持到下一个 Tile。
            array_done <= 1'b0;
            if (collect_done) begin
                array_done <= 1'b1;
            end
        end
    end

endmodule
