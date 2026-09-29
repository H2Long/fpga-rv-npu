// cpu_port_ctrl — 将 CPU 的局部地址、写数据、byte enable 转换为三块 RAM 的端口操作
// 写数据按字节使能屏蔽;读地址直接送 RAM 的 CPU 侧端口。
`include "npu_defines.vh"

module cpu_port_ctrl(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        cpu_a_we,  cpu_a_re,
    input  wire        cpu_bt_we, cpu_bt_re,
    input  wire        cpu_c_we,  cpu_c_re,
    input  wire [`NPU_ABUF_AW-1:0] cpu_a_addr,
    input  wire [`NPU_BBUF_AW-1:0] cpu_bt_addr,
    input  wire [`NPU_CBUF_AW-1:0] cpu_c_addr,
    input  wire [31:0] cpu_buf_wdata,
    input  wire [3:0]  cpu_buf_byte_en,
    // 到三块 RAM 的 CPU 端口
    output wire [`NPU_ABUF_AW-1:0] ram_a_addr,
    output wire [`NPU_BBUF_AW-1:0] ram_bt_addr,
    output wire [`NPU_CBUF_AW-1:0] ram_c_addr,
    output wire        ram_a_we,  ram_a_re,
    output wire        ram_bt_we, ram_bt_re,
    output wire        ram_c_we,  ram_c_re,
    output wire [31:0] ram_a_wdata, ram_bt_wdata, ram_c_wdata
);

    wire [31:0] byte_mask = {{8{cpu_buf_byte_en[3]}}, {8{cpu_buf_byte_en[2]}},
                             {8{cpu_buf_byte_en[1]}}, {8{cpu_buf_byte_en[0]}}};
    wire [31:0] masked_wdata = cpu_buf_wdata & byte_mask;

    assign ram_a_addr  = cpu_a_addr;
    assign ram_bt_addr = cpu_bt_addr;
    assign ram_c_addr  = cpu_c_addr;
    assign ram_a_we  = cpu_a_we;   assign ram_a_re  = cpu_a_re;
    assign ram_bt_we = cpu_bt_we;  assign ram_bt_re = cpu_bt_re;
    assign ram_c_we  = cpu_c_we;   assign ram_c_re  = cpu_c_re;
    assign ram_a_wdata  = masked_wdata;
    assign ram_bt_wdata = masked_wdata;
    assign ram_c_wdata  = masked_wdata;

endmodule
