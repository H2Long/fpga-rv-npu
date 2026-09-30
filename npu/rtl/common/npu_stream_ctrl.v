`timescale 1ns / 1ps
// npu_stream_ctrl — 连续地址读突发控制器
//
// start_in 收到一拍脉冲后，从 base_in 开始连续发出 len_in 个读请求：
//   start_in 当拍发出第 1 个请求，之后每个时钟沿地址加 1，发满 len_in 个后停止；
//   len_in=0 时不产生任何请求；突发长度和起始地址在 start_in 当拍被锁存，
//   之后改动 base_in/len_in 不影响本次突发。
// busy_out=1 表示突发还没发完；此时再给 start_in 会重新开始本次突发，
// 上层必须用 busy_out 或等价的时序保证两次启动不重叠。
// rd_re_out 是读请求，RAM 数据在请求后一拍返回（见 npu_ram）。
`include "npu_defines.vh"

module npu_stream_ctrl #(parameter AW = `NPU_ABUF_AW) (
    input        clk,
    input        rst,
    input [AW-1:0] base_in,
    input [`NPU_TK_W-1:0] len_in,
    input        start_in,
    output reg [AW-1:0] rd_addr_out,
    output reg   rd_re_out,
    output reg   busy_out
);

    reg [`NPU_TK_W-1:0] left_q;      // 本次突发还没发出的请求数

    always @(posedge clk) begin
        if (rst) begin
            rd_addr_out <= {AW{1'b0}};
            rd_re_out   <= 1'b0;
            busy_out    <= 1'b0;
            left_q      <= {`NPU_TK_W{1'b0}};
        end else begin
            rd_re_out <= 1'b0;
            if (start_in && (len_in != 0)) begin
                // 第 1 个请求在启动当拍发出，剩余 len-1 个逐拍发出。
                rd_addr_out <= base_in;
                rd_re_out   <= 1'b1;
                left_q      <= len_in - 1'b1;
                busy_out    <= (len_in > 1'b1);
            end else if (busy_out) begin
                rd_addr_out <= rd_addr_out + 1'b1;
                rd_re_out   <= 1'b1;
                left_q      <= left_q - 1'b1;
                busy_out    <= (left_q > 1'b1);
            end
        end
    end

endmodule
