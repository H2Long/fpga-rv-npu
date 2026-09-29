`timescale 1ns / 1ps
// start_ctrl — 管理一整次任务的生命周期 IDLE -> RUNNING -> DONE -> IDLE
//
// IDLE：接受 start_req，锁存全部配置并产生一个时钟周期的 start_pulse。
// RUN ：保持 BUSY=1，忽略新的 start_req，直到 core_done_i 到来。
// DONE：保持 DONE=1；只有收到 clear_done_req 才回到 IDLE。
// 因此向 CTRL(0x00) 写 0x02 的作用是 DONE -> IDLE，不会清除配置寄存器。
`include "npu_defines.vh"

module start_ctrl(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start_req,
    input  wire        clear_done_req,
    input  wire [`NPU_DIM_W-1:0]  cfg_m, cfg_n, cfg_k,
    input  wire [`NPU_TILE_W-1:0] cfg_tm, cfg_tn,
    input  wire [`NPU_TK_W-1:0]   cfg_tk,
    input  wire [`NPU_QS_W-1:0]   cfg_qshift,
    input  wire        core_done_i,
    output reg         start_pulse,
    output reg  [`NPU_DIM_W-1:0]  m_l, n_l, k_l,
    output reg  [`NPU_TILE_W-1:0] tm_l, tn_l,
    output reg  [`NPU_TK_W-1:0]   tk_l,
    output reg  [`NPU_QS_W-1:0]   qs_l,
    output wire        busy_status,
    output wire        done_status
);

    localparam ST_IDLE = 2'd0, ST_RUN = 2'd1, ST_DONE = 2'd2;
    reg [1:0] state;

    assign busy_status = (state == ST_RUN);
    assign done_status = (state == ST_DONE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE; start_pulse <= 1'b0;
            m_l <= 6'd0; n_l <= 6'd0; k_l <= 6'd0;
            tm_l <= 3'd0; tn_l <= 3'd0; tk_l <= 5'd0; qs_l <= 5'd0;
        end else begin
            start_pulse <= 1'b0;
            case (state)
                ST_IDLE: begin
                    if (start_req) begin
                        m_l <= cfg_m;   n_l <= cfg_n;   k_l <= cfg_k;
                        tm_l <= cfg_tm; tn_l <= cfg_tn; tk_l <= cfg_tk;
                        qs_l <= cfg_qshift;
                        start_pulse <= 1'b1;
                        state <= ST_RUN;
                    end
                end
                ST_RUN: begin
                    if (core_done_i)
                        state <= ST_DONE;
                end
                ST_DONE: begin
                    if (clear_done_req)
                        state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
