`timescale 1ns / 1ps
// npu_stream_ctrl — 通用连续地址读流控制器
//
// prefetch_go=1 时，控制器从 base 开始连续发出 len 个读请求：
//   第 0 个请求地址为 base；之后每个有效周期地址加 1；
//   发出第 len 个请求后，rd_re 自动拉低；
//   prefetch_go=0 会清零计数器，下一次启动从 base 重新开始。
`include "npu_defines.vh"

module npu_stream_ctrl(
    input        clk,
    input        rst,
    input [`NPU_ABUF_AW-1:0] base,
    input [`NPU_TK_W-1:0]    len,
    input        go,
    output reg  [`NPU_ABUF_AW-1:0] rd_addr,
    output reg         rd_re
);

    // 比 len 多一位，允许比较到“已经发完”的状态。
    reg [`NPU_TK_W:0] cnt;

    always @(posedge clk) begin
        if (rst) begin
            cnt     <= {(`NPU_TK_W + 1){1'b0}};
            rd_addr <= {`NPU_ABUF_AW{1'b0}};
            rd_re   <= 1'b0;
        end else if (!go) begin
            cnt   <= {(`NPU_TK_W + 1){1'b0}};
            rd_re <= 1'b0;
        end else begin
            if (cnt < {1'b0, len}) begin
                rd_re   <= 1'b1;
                rd_addr <= base + cnt[`NPU_ABUF_AW-1:0];
                cnt     <= cnt + {{`NPU_TK_W{1'b0}}, 1'b1};
            end else begin
                rd_re <= 1'b0;
            end
        end
    end
endmodule
