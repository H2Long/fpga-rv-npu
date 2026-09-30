`timescale 1ns / 1ps
// addr_decoder — CPU MMIO 地址译码
//
// 本模块是纯组合逻辑，不保存请求。req_addr 已由 mmio_if 锁存，
// 这里根据高位产生目标选择信号，并把 Buffer 字节地址转换为 RAM 字地址：
//   0x0000-0x001F  控制寄存器，ctrl_reg_off=req_addr[4:2]
//   0x0020-0x002F  状态寄存器，ctrl_reg_off=0/1 对应 STATUS/ERR_CODE
//   0x1000-0x10FF  A Buffer，局部地址=(req_addr-0x1000)>>2
//   0x2000-0x20FF  BT Buffer，局部地址=(req_addr-0x2000)>>2
//   0x3000-0x33FF  C Buffer，局部地址=(req_addr-0x3000)>>2
`include "npu_defines.vh"

module addr_decoder(
    input [31:0] req_addr,
    output reg        sel_ctrl,
    output reg        sel_status,
    output reg        sel_buffer,
    output reg        sel_a_buf,
    output reg        sel_bt_buf,
    output reg        sel_c_buf,
    output reg [`NPU_ABUF_AW-1:0] a_local_addr,   // (addr - 0x1000)>>2
    output reg [`NPU_BBUF_AW-1:0] bt_local_addr,  // (addr - 0x2000)>>2
    output reg [`NPU_CBUF_AW-1:0] c_local_addr,   // (addr - 0x3000)>>2
    output reg [2:0]  ctrl_reg_off                 // 寄存器内偏移 addr[4:2]
);

    always @(*) begin
        // 控制/状态寄存器按 32 字节窗口译码；低两位地址应保持字对齐。
        sel_ctrl   = (req_addr[31:5] == 27'd0);
        sel_status = (req_addr[31:5] == 27'd1);
        sel_a_buf  = (req_addr[31:16] == 16'd0) && (req_addr[15:12] == 4'h1);
        sel_bt_buf = (req_addr[31:16] == 16'd0) && (req_addr[15:12] == 4'h2);
        sel_c_buf  = (req_addr[31:16] == 16'd0) && (req_addr[15:12] == 4'h3);
        sel_buffer = sel_a_buf | sel_bt_buf | sel_c_buf;

        // A/BT 每块有 64 个 32 位字，因此使用地址 [7:2]。
        a_local_addr  = req_addr[7:2];
        bt_local_addr = req_addr[7:2];
        // C Buffer 有 256 个 32 位字，因此使用地址 [9:2]。
        c_local_addr  = req_addr[9:2];
        ctrl_reg_off  = req_addr[4:2];
    end

endmodule
