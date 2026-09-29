// done_ctrl — 只有最后一个输出 tile 的最后一笔 C 写真正写入 C RAM 后才产生 core_done;
// 配置错误时立即 core_done(带错误码)。不能在结果仅进入写 FIFO 时提前完成。
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

    wire [TOTAL_W-1:0] wr_cnt_next = wr_cnt + {8'd0, c_wr_pulse};
    wire fire = !done_seen &&
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
