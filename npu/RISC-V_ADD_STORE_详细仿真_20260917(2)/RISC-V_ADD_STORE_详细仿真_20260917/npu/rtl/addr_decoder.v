// addr_decoder — 按 CPU 字节地址选择访问目标,不保存任何数据
// 0x0000-0x001F 控制寄存器 | 0x0020-0x002F 状态寄存器
// 0x1000-0x10FF A Buffer | 0x2000-0x20FF BT Buffer | 0x3000-0x33FF C Buffer
`include "npu_defines.vh"

module addr_decoder(
    input  wire [31:0] req_addr,
    output wire        sel_ctrl,
    output wire        sel_status,
    output wire        sel_buffer,
    output wire        sel_a_buf,
    output wire        sel_bt_buf,
    output wire        sel_c_buf,
    output wire [`NPU_ABUF_AW-1:0] a_local_addr,   // (addr - 0x1000)>>2
    output wire [`NPU_BBUF_AW-1:0] bt_local_addr,  // (addr - 0x2000)>>2
    output wire [`NPU_CBUF_AW-1:0] c_local_addr,   // (addr - 0x3000)>>2
    output wire [2:0]  ctrl_reg_off                 // 寄存器内偏移 addr[4:2]
);

    assign sel_ctrl   = (req_addr[31:5] == 27'd0);
    assign sel_status = (req_addr[31:5] == 27'd1);
    assign sel_a_buf  = (req_addr[31:16] == 16'd0) && (req_addr[15:12] == 4'h1);
    assign sel_bt_buf = (req_addr[31:16] == 16'd0) && (req_addr[15:12] == 4'h2);
    assign sel_c_buf  = (req_addr[31:16] == 16'd0) && (req_addr[15:12] == 4'h3);
    assign sel_buffer = sel_a_buf | sel_bt_buf | sel_c_buf;

    assign a_local_addr  = req_addr[7:2];
    assign bt_local_addr = req_addr[7:2];
    assign c_local_addr  = req_addr[9:2];
    assign ctrl_reg_off  = req_addr[4:2];

endmodule
