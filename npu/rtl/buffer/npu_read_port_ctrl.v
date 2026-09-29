// npu_read_port_ctrl — 驱动 A/BT RAM 的 NPU 读端口,并把同步 RAM 返回
// 与请求顺序对应起来:读请求 1 拍后数据有效,按序推入预取 FIFO。
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
            a_re_d  <= a_re  && core_busy;   // 同步 RAM:re 后 1 拍数据有效
            bt_re_d <= bt_re && core_busy;
        end
    end

    assign a_fifo_push  = a_re_d;
    assign bt_fifo_push = bt_re_d;

endmodule
