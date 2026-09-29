// a_stream_ctrl — A tile 读流控制:根据 A tile 字基地址发起 RAM 读,
// 处理按 valid_tk 截断的边界(越界 k 不读取)。
`include "npu_defines.vh"

module a_stream_ctrl(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [`NPU_ABUF_AW-1:0] a_base,
    input  wire [`NPU_TK_W-1:0]    valid_tk,
    input  wire        prefetch_go,
    output wire [`NPU_ABUF_AW-1:0] a_addr,
    output wire        a_re
);

    npu_stream_ctrl u_stream(
        .clk(clk), .rst_n(rst_n),
        .base(a_base), .len(valid_tk), .go(prefetch_go),
        .rd_addr(a_addr), .rd_re(a_re), .issue_done()
    );

endmodule
