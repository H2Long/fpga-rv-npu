`timescale 1ns / 1ps
// done_ctrl — 任务完成判定
//
// c_wr_pulse 是 C RAM 的实际写脉冲，而不是 FIFO 入队脉冲。
// 只有 FSM 已经到达 DONE 且 wr_cnt_next >= M*N 时，才产生一个周期的 core_done。
// 配置错误由 err_abort 直接结束任务；done_seen 防止同一任务重复发出完成脉冲。
`include "npu_defines.vh"

module done_ctrl(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start_pulse,
    input  wire [`NPU_DIM_W-1:0] lp_m, lp_n,
    input  wire        c_wr_pulse,          // c_write_fifo -> C RAM 实际写入脉冲
    input  wire        fsm_done,            // systolic_fsm 已到 DONE
    input  wire        err_abort,           // 配置错误中止
    output reg         core_done
);

    localparam TOTAL_W = 9;   // M*N <= 256
    wire [TOTAL_W-1:0] total = lp_m * lp_n;

    reg [TOTAL_W-1:0] wr_cnt;
    reg               done_seen;

    wire [TOTAL_W-1:0] wr_cnt_next;
    wire               fire;

    assign wr_cnt_next = wr_cnt + {{(TOTAL_W-1){1'b0}}, c_wr_pulse};
    assign fire = !done_seen &&
                  ((fsm_done && (wr_cnt_next >= total)) || err_abort);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_cnt <= 9'd0; done_seen <= 1'b0; core_done <= 1'b0;
        end else begin
            core_done <= 1'b0;
            if (start_pulse) begin
                wr_cnt <= 9'd0; done_seen <= 1'b0;
            end else begin
                wr_cnt <= wr_cnt_next;
                if (fire) begin
                    core_done <= 1'b1;
                    done_seen <= 1'b1;
                end
            end
        end
    end
endmodule
