// mac_status — 汇总 MAC Tile 完成状态。
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
            array_done <= 1'b0;
            if (collect_done) begin
                array_done <= 1'b1;
            end
        end
    end

endmodule
