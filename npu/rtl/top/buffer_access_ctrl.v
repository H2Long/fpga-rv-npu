`timescale 1ns / 1ps
// buffer_access_ctrl — CPU Buffer 访问仲裁与读数据复用
//
// core_busy=0 时 CPU 拥有 A/BT/C 的访问端口；core_busy=1 时 NPU 正在使用
// Buffer，所有 CPU 读写使能都被屏蔽。注意：本模块屏蔽的是 RAM 端口，
// mmio_if 仍会按正常 MMIO 时序给出 cpu_ready。
// 三块 RAM 的 CPU 读数据通过 sel_a_buf/sel_bt_buf/sel_c_buf 复用为 buffer_rdata。
`include "npu_defines.vh"

module buffer_access_ctrl(
    input  wire        clk,
    input  wire        rst_n,
    // 来自 addr_decoder 的 CPU 请求(已锁存于 mmio_if)
    input  wire        req_valid,
    input  wire        req_we,
    input  wire [3:0]  req_byte_en,
    input  wire        sel_a_buf,
    input  wire        sel_bt_buf,
    input  wire        sel_c_buf,
    input  wire [`NPU_ABUF_AW-1:0] a_local_addr,
    input  wire [`NPU_BBUF_AW-1:0] bt_local_addr,
    input  wire [`NPU_CBUF_AW-1:0] c_local_addr,
    input  wire [31:0] req_wdata,
    // NPU 状态
    input  wire        core_busy,
    // 到 cpu_port_ctrl(仅 core_busy=0 时放行)
    output wire        cpu_a_we,  cpu_a_re,
    output wire        cpu_bt_we, cpu_bt_re,
    output wire        cpu_c_we,  cpu_c_re,
    output wire [`NPU_ABUF_AW-1:0] cpu_a_addr,
    output wire [`NPU_BBUF_AW-1:0] cpu_bt_addr,
    output wire [`NPU_CBUF_AW-1:0] cpu_c_addr,
    output wire [31:0] cpu_buf_wdata,
    output wire [3:0]  cpu_buf_byte_en,
    // Buffer 读数据返回(CPU 侧)
    input  wire [31:0] a_rdata_cpu,
    input  wire [31:0] bt_rdata_cpu,
    input  wire [31:0] c_rdata_cpu,
    output wire [31:0] buffer_rdata,
    // Buffer 可用状态由 npu_buffer 根据 core_busy 直接输出。
    output wire        buffer_ready
);

    wire cpu_ok;

    // Buffer_READY 与 cpu_ok 同源；状态寄存器 bit3 用它告诉软件当前能否装载/读取数据。
    assign cpu_ok = !core_busy;

    assign cpu_a_we  = req_valid && req_we  && sel_a_buf  && cpu_ok;
    assign cpu_a_re  = req_valid && !req_we && sel_a_buf  && cpu_ok;
    assign cpu_bt_we = req_valid && req_we  && sel_bt_buf && cpu_ok;
    assign cpu_bt_re = req_valid && !req_we && sel_bt_buf && cpu_ok;
    assign cpu_c_we  = req_valid && req_we  && sel_c_buf  && cpu_ok;
    assign cpu_c_re  = req_valid && !req_we && sel_c_buf  && cpu_ok;

    assign cpu_a_addr  = a_local_addr;
    assign cpu_bt_addr = bt_local_addr;
    assign cpu_c_addr  = c_local_addr;
    assign cpu_buf_wdata   = req_wdata;
    assign cpu_buf_byte_en = req_byte_en;

    // req_addr 已经被 mmio_if 锁存，所以 sel_* 在整个 Buffer 读等待期间保持稳定。
    assign buffer_rdata = sel_a_buf  ? a_rdata_cpu  :
                          sel_bt_buf ? bt_rdata_cpu : c_rdata_cpu;
    assign buffer_ready = cpu_ok;

endmodule
