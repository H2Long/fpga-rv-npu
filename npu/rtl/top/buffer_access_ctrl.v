`timescale 1ns / 1ps
// buffer_access_ctrl — CPU Buffer 访问仲裁与读数据复用
//
// core_busy=0 时 CPU 拥有 A/BT/C 的访问端口；core_busy=1 时 NPU 正在使用
// Buffer，所有 CPU 读写使能都被屏蔽。注意：本模块屏蔽的是 RAM 端口，
// mmio_if 仍会按正常 MMIO 时序给出 cpu_ready；同时完成 CPU 写数据的
// 字节屏蔽，直接输出三组 RAM 端口。
// 三块 RAM 的 CPU 读数据通过 sel_a_buf/sel_bt_buf/sel_c_buf 复用为 buffer_rdata。
`include "npu_defines.vh"

module buffer_access_ctrl(
    // 来自 npu_top 内联译码的 CPU 请求(地址已由 mmio_if 锁存)
    input        req_valid,
    input        req_we,
    input [3:0]  req_byte_en,
    input        sel_a_buf,
    input        sel_bt_buf,
    input        sel_c_buf,
    input [`NPU_ABUF_AW-1:0] a_local_addr,
    input [`NPU_BBUF_AW-1:0] bt_local_addr,
    input [`NPU_CBUF_AW-1:0] c_local_addr,
    input [31:0] req_wdata,
    // NPU 状态
    input        core_busy,
    // 到 Buffer RAM(仅 core_busy=0 时放行)
    output reg        cpu_a_we,  cpu_a_re,
    output reg        cpu_bt_we, cpu_bt_re,
    output reg        cpu_c_we,  cpu_c_re,
    output reg [`NPU_ABUF_AW-1:0] cpu_a_addr,
    output reg [`NPU_BBUF_AW-1:0] cpu_bt_addr,
    output reg [`NPU_CBUF_AW-1:0] cpu_c_addr,
    output reg [31:0] cpu_a_wdata,
    output reg [31:0] cpu_bt_wdata,
    output reg [31:0] cpu_c_wdata,
    // Buffer 读数据返回(CPU 侧)
    input [31:0] a_rdata_cpu,
    input [31:0] bt_rdata_cpu,
    input [31:0] c_rdata_cpu,
    output reg [31:0] buffer_rdata
);

    reg cpu_ok;
    reg [31:0] byte_mask;

    always @(*) begin
        // Buffer_READY 与 cpu_ok 同源；状态寄存器 bit3 用它告诉软件当前能否装载/读取数据。
        cpu_ok = !core_busy;
        cpu_a_we  = req_valid && req_we  && sel_a_buf  && cpu_ok;
        cpu_a_re  = req_valid && !req_we && sel_a_buf  && cpu_ok;
        cpu_bt_we = req_valid && req_we  && sel_bt_buf && cpu_ok;
        cpu_bt_re = req_valid && !req_we && sel_bt_buf && cpu_ok;
        cpu_c_we  = req_valid && req_we  && sel_c_buf  && cpu_ok;
        cpu_c_re  = req_valid && !req_we && sel_c_buf  && cpu_ok;
        cpu_a_addr  = a_local_addr;
        cpu_bt_addr = bt_local_addr;
        cpu_c_addr  = c_local_addr;
        byte_mask = {{8{req_byte_en[3]}}, {8{req_byte_en[2]}},
                     {8{req_byte_en[1]}}, {8{req_byte_en[0]}}};
        cpu_a_wdata  = req_wdata & byte_mask;
        cpu_bt_wdata = req_wdata & byte_mask;
        cpu_c_wdata  = req_wdata & byte_mask;

        // req_addr 已经被 mmio_if 锁存，所以 sel_* 在整个 Buffer 读等待期间保持稳定。
        buffer_rdata = sel_a_buf  ? a_rdata_cpu  :
                       sel_bt_buf ? bt_rdata_cpu : c_rdata_cpu;
    end

endmodule
