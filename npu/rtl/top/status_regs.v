`timescale 1ns / 1ps
// status_regs — 向 CPU 提供只读运行状态
//
// 0x20 STATUS：
//   bit0 BUSY         start_ctrl 处于 RUN 状态
//   bit1 DONE         start_ctrl 处于 DONE 状态
//   bit2 ERROR        error_code_i != NPU_ERR_NONE
//   bit3 BUFFER_READY !core_busy，CPU 可以访问 A/BT/C Buffer
//   bit31:4 保留，读出为 0
// 0x24 ERR_CODE：bit7:0 为错误码，bit31:8 保留，读出为 0。
// 本模块没有写入逻辑，req_we 仅作为接口保留；写 STATUS/ERR_CODE 不改变状态。
`include "npu_defines.vh"

module status_regs(
    input  wire                 req_we,          // 只读窗口保留该端口，当前不参与译码
    input  wire [2:0]           ctrl_reg_off,   // 复用 addr 低位(0x20->0, 0x24->1)
    input  wire                 busy_i,
    input  wire                 done_i,
    input  wire                 error_i,
    input  wire                 buffer_ready_i,
    input  wire [`NPU_ERR_W-1:0] error_code_i,
    output wire [31:0]          status_rdata
);

    // addr_decoder 将 0x20 映射为 ctrl_reg_off=0，将 0x24 映射为 1。
    assign status_rdata = (ctrl_reg_off == 3'd0) ?
        {28'd0, buffer_ready_i, error_i, done_i, busy_i} :
        {24'd0, error_code_i};

endmodule
