`timescale 1ns / 1ps
// npu_top — CPU 控制平面
//
// 本模块把 CPU 的 MMIO 总线拆成三个方向：
//   1. 控制寄存器：保存 M/N/K、TK、量化参数；TM/TN 固定为 4；
//   2. 状态寄存器：返回 BUSY、DONE 和 BUFFER_READY；
//   3. Buffer 端口：把 0x1000/0x2000/0x3000 地址窗口转换成 RAM 操作。
//
// start_ctrl 在 start_req 到来时锁存配置并产生 start_pulse，运行期间软件
// 再写配置寄存器不会修改当前任务使用的参数。
// 内含模块：mmio_if / control_regs / start_ctrl / buffer_access_ctrl
`include "npu_defines.vh"

module npu_top(
    input        clk,
    input        rst,
    // CPU MMIO 总线
    input [31:0] cpu_addr,
    input [31:0] cpu_wdata,
    input [3:0]  cpu_byte_en,
    input        cpu_we,
    input        cpu_valid,
    output reg [31:0] cpu_rdata,
    output reg        cpu_ready,
    // 到 tile_controller(启动脉冲 + 锁存后的任务参数)
    output reg        start_pulse,
    output reg [`NPU_DIM_W-1:0]  cfg_m, cfg_n, cfg_k,
    output reg [`NPU_TK_W-1:0]   cfg_tk,
    output reg [`NPU_QS_W-1:0]   cfg_qshift,
    // 来自 tile_controller
    input        core_busy,
    input        core_done,
    // CPU 侧 RAM 端口(到 npu_buffer)
    output reg        cpu_a_we,  cpu_a_re,
    output reg        cpu_bt_we, cpu_bt_re,
    output reg        cpu_c_we,  cpu_c_re,
    output reg [`NPU_ABUF_AW-1:0] cpu_a_addr,
    output reg [`NPU_BBUF_AW-1:0] cpu_bt_addr,
    output reg [`NPU_CBUF_AW-1:0] cpu_c_addr,
    output reg [31:0] cpu_a_wdata, cpu_bt_wdata, cpu_c_wdata,
    input [31:0] a_rdata_cpu, bt_rdata_cpu, c_rdata_cpu
);

    // ---- 内部连线：MMIO 锁存请求 ----
    wire [31:0] req_addr, req_wdata;
    wire [3:0]  req_byte_en;
    wire        req_we, req_valid;
    wire        sel_ctrl, sel_status, sel_buffer;
    wire        sel_a_buf, sel_bt_buf, sel_c_buf;
    wire [`NPU_ABUF_AW-1:0] a_local_addr;
    wire [`NPU_BBUF_AW-1:0] bt_local_addr;
    wire [`NPU_CBUF_AW-1:0] c_local_addr;
    wire [2:0]  ctrl_reg_off;

    wire [31:0] control_rdata, buffer_rdata_w;
    wire [31:0] status_rdata;

    // start_ctrl 的锁存参数：任务开始后由 m_l..qs_l 保持到任务结束。
    wire [`NPU_DIM_W-1:0]  m_l, n_l, k_l;
    wire [`NPU_TK_W-1:0]   tk_l;
    wire [`NPU_QS_W-1:0]   qs_l;
    wire        busy_status, done_status;
    wire        start_req, clear_done_req;

    // Buffer 端口控制器直接输出经过字节屏蔽的 RAM 端口。
    wire [31:0] cpu_rdata_w;
    wire        cpu_ready_w;
    wire        start_pulse_w;
    wire        cpu_a_we_w, cpu_a_re_w, cpu_bt_we_w, cpu_bt_re_w;
    wire        cpu_c_we_w, cpu_c_re_w;
    wire [`NPU_ABUF_AW-1:0] cpu_a_addr_w;
    wire [`NPU_BBUF_AW-1:0] cpu_bt_addr_w;
    wire [`NPU_CBUF_AW-1:0] cpu_c_addr_w;
    wire [31:0] cpu_a_wdata_w, cpu_bt_wdata_w, cpu_c_wdata_w;

    // ---- mmio_if ----
    mmio_if u_mmio_if(
        .clk(clk), .rst(rst),
        .cpu_valid(cpu_valid), .cpu_we(cpu_we),
        .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata), .cpu_byte_en(cpu_byte_en),
        .cpu_ready(cpu_ready_w), .cpu_rdata(cpu_rdata_w),
        .req_addr(req_addr), .req_wdata(req_wdata),
        .req_byte_en(req_byte_en), .req_we(req_we), .req_valid(req_valid),
        .sel_ctrl(sel_ctrl), .sel_status(sel_status), .sel_buffer(sel_buffer),
        .control_rdata(control_rdata), .status_rdata(status_rdata),
        .buffer_rdata(buffer_rdata_w)
    );

    // ---- MMIO 地址译码：req_addr 已由 mmio_if 锁存 ----
    assign sel_ctrl   = (req_addr[31:5] == 27'd0);
    assign sel_status = (req_addr[31:4] == 28'h0000002); // 0x0020-0x002F
    assign sel_a_buf  = (req_addr[31:8] == 24'h000010);  // 0x1000-0x10FF
    assign sel_bt_buf = (req_addr[31:8] == 24'h000020);  // 0x2000-0x20FF
    assign sel_c_buf  = (req_addr[31:10] == 22'h00000C); // 0x3000-0x33FF
    assign sel_buffer = sel_a_buf | sel_bt_buf | sel_c_buf;
    assign a_local_addr  = req_addr[7:2];
    assign bt_local_addr = req_addr[7:2];
    assign c_local_addr  = req_addr[9:2];
    assign ctrl_reg_off  = req_addr[4:2];

    // control_regs 的实时配置值，仅供 start_ctrl 在启动瞬间采样。
    wire [`NPU_DIM_W-1:0]  cr_m, cr_n, cr_k;
    wire [`NPU_TK_W-1:0]   cr_tk;
    wire [`NPU_QS_W-1:0]   cr_qs;

    // ---- control_regs ----
    control_regs u_control_regs(
        .clk(clk), .rst(rst),
        .req_valid(req_valid), .req_we(req_we), .sel_ctrl(sel_ctrl),
        .ctrl_reg_off(ctrl_reg_off), .req_wdata(req_wdata),
        .req_byte_en(req_byte_en),
        .cfg_m(cr_m), .cfg_n(cr_n), .cfg_k(cr_k),
        .cfg_tk(cr_tk), .cfg_qshift(cr_qs),
        .start_req(start_req), .clear_done_req(clear_done_req),
        .control_rdata(control_rdata)
    );

    // ---- 状态寄存器读数据 ----
    assign status_rdata = (ctrl_reg_off == 3'd0) ?
        {28'd0, !core_busy, 1'b0, done_status, busy_status} :
        32'd0;

    // ---- start_ctrl ----
    start_ctrl u_start_ctrl(
        .clk(clk), .rst(rst),
        .start_req(start_req), .clear_done_req(clear_done_req),
        .cfg_m(cr_m), .cfg_n(cr_n), .cfg_k(cr_k),
        .cfg_tk(cr_tk), .cfg_qshift(cr_qs),
        .core_done_i(core_done),
        .start_pulse(start_pulse_w),
        .m_l(m_l), .n_l(n_l), .k_l(k_l),
        .tk_l(tk_l), .qs_l(qs_l),
        .busy_status(busy_status), .done_status(done_status)
    );

    // 对 tile_controller 输出锁存后的任务参数；运行期间软件改动不影响当前任务。
    // ---- buffer_access_ctrl ----
    buffer_access_ctrl u_buffer_access_ctrl(
        .req_valid(req_valid), .req_we(req_we), .req_byte_en(req_byte_en),
        .sel_a_buf(sel_a_buf), .sel_bt_buf(sel_bt_buf), .sel_c_buf(sel_c_buf),
        .a_local_addr(a_local_addr), .bt_local_addr(bt_local_addr),
        .c_local_addr(c_local_addr), .req_wdata(req_wdata),
        .core_busy(core_busy),
        .cpu_a_we(cpu_a_we_w), .cpu_a_re(cpu_a_re_w),
        .cpu_bt_we(cpu_bt_we_w), .cpu_bt_re(cpu_bt_re_w),
        .cpu_c_we(cpu_c_we_w), .cpu_c_re(cpu_c_re_w),
        .cpu_a_addr(cpu_a_addr_w), .cpu_bt_addr(cpu_bt_addr_w), .cpu_c_addr(cpu_c_addr_w),
        .cpu_a_wdata(cpu_a_wdata_w), .cpu_bt_wdata(cpu_bt_wdata_w), .cpu_c_wdata(cpu_c_wdata_w),
        .a_rdata_cpu(a_rdata_cpu), .bt_rdata_cpu(bt_rdata_cpu),
        .c_rdata_cpu(c_rdata_cpu), .buffer_rdata(buffer_rdata_w)
    );

    always @(*) begin
        cpu_rdata = cpu_rdata_w;
        cpu_ready = cpu_ready_w;
        start_pulse = start_pulse_w;
        cfg_m = m_l;
        cfg_n = n_l;
        cfg_k = k_l;
        cfg_tk = tk_l;
        cfg_qshift = qs_l;
        cpu_a_we = cpu_a_we_w;
        cpu_a_re = cpu_a_re_w;
        cpu_bt_we = cpu_bt_we_w;
        cpu_bt_re = cpu_bt_re_w;
        cpu_c_we = cpu_c_we_w;
        cpu_c_re = cpu_c_re_w;
        cpu_a_addr = cpu_a_addr_w;
        cpu_bt_addr = cpu_bt_addr_w;
        cpu_c_addr = cpu_c_addr_w;
        cpu_a_wdata = cpu_a_wdata_w;
        cpu_bt_wdata = cpu_bt_wdata_w;
        cpu_c_wdata = cpu_c_wdata_w;
    end

endmodule
