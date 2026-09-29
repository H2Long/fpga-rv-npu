`timescale 1ns / 1ps
// npu_read_port_ctrl — 对齐同步 RAM 的读请求与返回数据
//
// A/BT RAM 的读数据固定在 read enable 后一拍返回。a_re_d/bt_re_d
// 保存上一拍的有效读请求，因此 a_fifo_push/bt_fifo_push 与当前 RAM 数据同拍。
// core_busy 是端口所有权条件：NPU 空闲时 CPU 使用 RAM，不能把 CPU 读混入预取 FIFO。
`include "npu_defines.vh"

module npu_read_port_ctrl(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        core_busy,
    // A 通道
    input  wire        a_re,
    output wire        a_fifo_push,
    // BT 通道
    input  wire        bt_re,
    output wire        bt_fifo_push
);

    reg a_re_d, bt_re_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_re_d <= 1'b0; bt_re_d <= 1'b0;
        end else begin
            // 同步 RAM：本拍发起 re，下一拍 RAM 输出对应数据。
            a_re_d  <= a_re  && core_busy;
            bt_re_d <= bt_re && core_busy;
        end
    end

    assign a_fifo_push  = a_re_d;
    assign bt_fifo_push = bt_re_d;

endmodule
