// status_regs — 向 CPU 提供运行状态
// 0x20 STATUS: bit0 BUSY | bit1 DONE | bit2 ERROR | bit3 BUFFER_READY
// 0x24 ERR_CODE
`include "npu_defines.vh"

module status_regs(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 req_valid,
    input  wire                 req_we,
    input  wire                 sel_status,
    input  wire [2:0]           ctrl_reg_off,   // 复用 addr 低位(0x20->0, 0x24->1)
    input  wire                 busy_i,
    input  wire                 done_i,
    input  wire                 error_i,
    input  wire                 buffer_ready_i,
    input  wire [`NPU_ERR_W-1:0] error_code_i,
    output wire [31:0]          status_rdata
);

    wire rd = sel_status && !req_we;    // 状态只读;写忽略

    assign status_rdata = (ctrl_reg_off == 3'd0) ?
        {28'd0, buffer_ready_i, error_i, done_i, busy_i} :
        {24'd0, error_code_i};

endmodule
