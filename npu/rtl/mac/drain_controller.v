`timescale 1ns / 1ps
// drain_controller — 阵列排空计数器
//
// 最后一对输入进入后，波前还要走 P+Q-2 个 enable 拍才能到达最远端 PE。
// 只在 drain_en_in=1 期间计数；drain_en_in=0 时计数器和 drain_done_out 立即复位，
// 所以每个输出 Tile 都是一次全新的排空，不需要额外复位输入。
// 注意：drain_done_out 在 drain_en_in 保持期间是电平而不是单拍脉冲
//（会多保持一拍，直到上层撤掉 drain_en_in），上层必须用"只消费一次"的方式使用它。
`include "npu_defines.vh"

module drain_controller(
    input        clk,
    input        rst,
    input        drain_en_in,
    output reg   drain_done_out
);

    localparam [3:0] DRAIN_BEATS = `NPU_P + `NPU_Q - 2;

    reg [3:0] cnt_q;

    always @(posedge clk) begin
        if (rst) begin
            cnt_q          <= 4'd0;
            drain_done_out <= 1'b0;
        end else if (!drain_en_in) begin
            cnt_q          <= 4'd0;
            drain_done_out <= 1'b0;
        end else if (!drain_done_out) begin
            if (cnt_q == DRAIN_BEATS - 4'd1)
                drain_done_out <= 1'b1;
            else
                cnt_q <= cnt_q + 4'd1;
        end
    end

endmodule
