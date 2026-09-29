// mac_status — 汇总 MAC 运行状态:array_ready / array_busy / array_done / error
`include "npu_defines.vh"

module mac_status(
    input  wire clk,
    input  wire rst_n,
    input  wire array_start,
    input  wire collect_done,     // 16 个结果全部送出
    output reg  array_busy,
    output wire array_ready,
    output reg  array_done,       // 单拍:本次 tile 结果流结束
    output wire error_flag
);

    assign array_ready = !array_busy;
    assign error_flag  = 1'b0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            array_busy <= 1'b0; array_done <= 1'b0;
        end else begin
            array_done <= 1'b0;
            if (array_start) begin
                array_busy <= 1'b1;
            end else if (collect_done) begin
                array_busy <= 1'b0;
                array_done <= 1'b1;
            end
        end
    end

endmodule
