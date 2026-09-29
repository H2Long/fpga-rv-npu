// npu_stream_ctrl — 通用 RAM 读流控制器:
// prefetch_go 期间按节拍发起连续同步 RAM 读(base..base+len-1),供 a/bt_stream_ctrl 复用。
`include "npu_defines.vh"

module npu_stream_ctrl(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [`NPU_ABUF_AW-1:0] base,
    input  wire [`NPU_TK_W-1:0]    len,
    input  wire        go,
    output reg  [`NPU_ABUF_AW-1:0] rd_addr,
    output reg         rd_re,
    output wire        issue_done        // len 个读请求已全部发出
);

    reg [`NPU_TK_W:0] cnt;

    assign issue_done = go && (cnt == {1'b0, len});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= 6'd0; rd_addr <= 6'd0; rd_re <= 1'b0;
        end else if (!go) begin
            cnt <= 6'd0; rd_re <= 1'b0;
        end else begin
            if (cnt < {1'b0, len}) begin
                rd_re   <= 1'b1;
                rd_addr <= base + cnt[`NPU_ABUF_AW-1:0];
                cnt     <= cnt + 6'd1;
            end else begin
                rd_re <= 1'b0;
            end
        end
    end
endmodule
