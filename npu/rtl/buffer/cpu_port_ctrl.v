`timescale 1ns / 1ps
// cpu_port_ctrl — CPU Buffer 端口适配器
//
// addr_decoder 已经把 MMIO 地址转换成 A/BT/C 的局部字地址；本模块只做两件事：
//   1. 将三路局部地址和读写使能直接传给对应 RAM；
//   2. 根据 byte_en 对写数据的四个字节进行屏蔽。
// 本模块不保存请求，也不产生 ready；请求生命周期由 mmio_if 管理。
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

    wire [31:0] byte_mask;
    wire [31:0] masked_wdata;

    assign byte_mask = {{8{cpu_buf_byte_en[3]}}, {8{cpu_buf_byte_en[2]}},
                        {8{cpu_buf_byte_en[1]}}, {8{cpu_buf_byte_en[0]}}};
    assign masked_wdata = cpu_buf_wdata & byte_mask;

    assign ram_a_addr  = cpu_a_addr;
    assign ram_bt_addr = cpu_bt_addr;
    assign ram_c_addr  = cpu_c_addr;
    assign ram_a_we      = cpu_a_we;
    assign ram_a_re      = cpu_a_re;
    assign ram_bt_we     = cpu_bt_we;
    assign ram_bt_re     = cpu_bt_re;
    assign ram_c_we      = cpu_c_we;
    assign ram_c_re      = cpu_c_re;
    assign ram_a_wdata   = masked_wdata;
    assign ram_bt_wdata  = masked_wdata;
    assign ram_c_wdata   = masked_wdata;

endmodule
