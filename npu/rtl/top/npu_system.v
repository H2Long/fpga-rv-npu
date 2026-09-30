`timescale 1ns / 1ps
// npu_system — NPU 唯一系统顶层
//
// 四个功能平面的边界固定在这里，顶层只负责端口连接，不执行算法：
//   npu_top    处理 CPU MMIO、配置寄存器和 CPU/Buffer 访问仲裁；
//   tile_controller 处理 Tile 循环、地址生成、阵列时序和 C 写回；
//   npu_buffer 处理 A/BT/C RAM、预取 FIFO 和 C 写 FIFO；
//   npu_mac    处理 INT8 拆包、波前对齐、PE 阵列和结果收集。
// 控制路径：CPU -> npu_top -> tile_controller -> npu_mac。
// 数据路径：A/BT Buffer -> 预取 FIFO -> MAC -> C 结果 FIFO -> C Buffer。
`include "npu_defines.vh"

module npu_system(
    input        clk,
    input        rst,
    // CPU MMIO 总线
    input [31:0] cpu_addr,
    input [31:0] cpu_wdata,
    input [3:0]  cpu_byte_en,
    input        cpu_we,
    input        cpu_valid,
    output reg [31:0] cpu_rdata,
    output reg        cpu_ready
);

    wire [31:0] cpu_rdata_w;
    wire        cpu_ready_w;

    // npu_top 与 tile_controller 之间的任务级控制接口。
    wire        start_pulse;
    wire [`NPU_DIM_W-1:0]  cfg_m, cfg_n, cfg_k;
    wire [`NPU_TK_W-1:0]   cfg_tk;
    wire [`NPU_QS_W-1:0]   cfg_qshift;
    wire        core_busy, core_done;

    // npu_top 与 npu_buffer 之间的 CPU 端口。
    wire        cpu_a_we, cpu_a_re, cpu_bt_we, cpu_bt_re, cpu_c_we, cpu_c_re;
    wire [`NPU_ABUF_AW-1:0] cpu_a_addr;
    wire [`NPU_BBUF_AW-1:0] cpu_bt_addr;
    wire [`NPU_CBUF_AW-1:0] cpu_c_addr;
    wire [31:0] cpu_a_wdata, cpu_bt_wdata, cpu_c_wdata;
    wire [31:0] a_rdata_cpu, bt_rdata_cpu, c_rdata_cpu;

    // tile_controller 发起 A/BT 读请求，npu_buffer 返回同步 RAM 数据和 FIFO 状态。
    wire [`NPU_ABUF_AW-1:0] npu_a_addr;
    wire        npu_a_re;
    wire [`NPU_BBUF_AW-1:0] npu_bt_addr;
    wire        npu_bt_re;
    wire        a_fifo_pop, bt_fifo_pop;
    wire [31:0] a_fifo_rdata, bt_fifo_rdata;
    wire [`NPU_FIFO_AW:0] a_fifo_count, bt_fifo_count;

    // tile_controller 到 npu_mac 的阵列控制、数据流和结果流。
    wire        array_start, array_enable, drain_en;
    wire        stream_valid;
    wire [31:0] a_stream_data, bt_stream_data;
    wire [3:0]  a_lane_en, bt_lane_en;
    wire        collect_done;
    wire        c_result_valid;
    wire [31:0] c_result;
    wire [3:0]  c_result_index;

    // tile_controller 到 npu_buffer 的 C 写回 FIFO 接口。
    wire        cwr_valid, cwr_ready, cwr_empty, c_wr_pulse;
    wire [`NPU_CBUF_AW-1:0] cwr_addr;
    wire [31:0] cwr_data;

    // ============ npu_top ============
    npu_top u_npu_top(
        .clk(clk), .rst(rst),
        .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata), .cpu_byte_en(cpu_byte_en),
        .cpu_we(cpu_we), .cpu_valid(cpu_valid),
        .cpu_rdata(cpu_rdata_w), .cpu_ready(cpu_ready_w),
        .start_pulse(start_pulse),
        .cfg_m(cfg_m), .cfg_n(cfg_n), .cfg_k(cfg_k),
        .cfg_tk(cfg_tk), .cfg_qshift(cfg_qshift),
        .core_busy(core_busy), .core_done(core_done),
        .cpu_a_we(cpu_a_we), .cpu_a_re(cpu_a_re),
        .cpu_bt_we(cpu_bt_we), .cpu_bt_re(cpu_bt_re),
        .cpu_c_we(cpu_c_we), .cpu_c_re(cpu_c_re),
        .cpu_a_addr(cpu_a_addr), .cpu_bt_addr(cpu_bt_addr), .cpu_c_addr(cpu_c_addr),
        .cpu_a_wdata(cpu_a_wdata), .cpu_bt_wdata(cpu_bt_wdata), .cpu_c_wdata(cpu_c_wdata),
        .a_rdata_cpu(a_rdata_cpu), .bt_rdata_cpu(bt_rdata_cpu), .c_rdata_cpu(c_rdata_cpu)
    );

    // ============ tile_controller ============
    tile_controller u_tile_controller(
        .clk(clk), .rst(rst),
        .start_pulse(start_pulse),
        .cfg_m(cfg_m), .cfg_n(cfg_n), .cfg_k(cfg_k),
        .cfg_tk(cfg_tk), .cfg_qshift(cfg_qshift),
        .a_addr(npu_a_addr), .a_re(npu_a_re),
        .bt_addr(npu_bt_addr), .bt_re(npu_bt_re),
        .a_fifo_rdata(a_fifo_rdata),
        .a_fifo_count(a_fifo_count), .a_fifo_pop(a_fifo_pop),
        .bt_fifo_rdata(bt_fifo_rdata),
        .bt_fifo_count(bt_fifo_count), .bt_fifo_pop(bt_fifo_pop),
        .array_start(array_start), .array_enable(array_enable),
        .drain_en(drain_en),
        .stream_valid(stream_valid), .a_stream_data(a_stream_data),
        .bt_stream_data(bt_stream_data),
        .a_lane_en(a_lane_en), .bt_lane_en(bt_lane_en),
        .collect_done(collect_done),
        .c_result_valid(c_result_valid), .c_result(c_result),
        .c_result_index(c_result_index),
        .cwr_valid(cwr_valid), .cwr_addr(cwr_addr), .cwr_data(cwr_data),
        .cwr_ready(cwr_ready), .cwr_empty(cwr_empty), .c_wr_pulse(c_wr_pulse),
        .core_busy(core_busy), .core_done(core_done)
    );

    // ============ npu_buffer ============
    npu_buffer u_npu_buffer(
        .clk(clk), .rst(rst), .core_busy(core_busy),
        .cpu_a_we(cpu_a_we), .cpu_a_re(cpu_a_re), .cpu_a_addr(cpu_a_addr),
        .cpu_a_wdata(cpu_a_wdata),
        .cpu_bt_we(cpu_bt_we), .cpu_bt_re(cpu_bt_re), .cpu_bt_addr(cpu_bt_addr),
        .cpu_bt_wdata(cpu_bt_wdata),
        .cpu_c_we(cpu_c_we), .cpu_c_re(cpu_c_re), .cpu_c_addr(cpu_c_addr),
        .cpu_c_wdata(cpu_c_wdata),
        .npu_a_addr(npu_a_addr), .npu_a_re(npu_a_re),
        .npu_bt_addr(npu_bt_addr), .npu_bt_re(npu_bt_re),
        .a_rdata_cpu(a_rdata_cpu), .bt_rdata_cpu(bt_rdata_cpu), .c_rdata_cpu(c_rdata_cpu),
        .a_fifo_rdata(a_fifo_rdata),
        .a_fifo_count(a_fifo_count), .a_fifo_pop(a_fifo_pop),
        .bt_fifo_rdata(bt_fifo_rdata),
        .bt_fifo_count(bt_fifo_count), .bt_fifo_pop(bt_fifo_pop),
        .cwr_valid(cwr_valid), .cwr_addr(cwr_addr), .cwr_data(cwr_data),
        .cwr_ready(cwr_ready), .cwr_empty(cwr_empty), .c_wr_pulse(c_wr_pulse)
    );

    // ============ npu_mac ============
    npu_mac u_npu_mac(
        .clk(clk), .rst(rst),
        .array_start(array_start), .array_enable(array_enable),
        .drain_en(drain_en),
        .stream_valid(stream_valid), .a_stream_data(a_stream_data),
        .bt_stream_data(bt_stream_data),
        .a_lane_en(a_lane_en), .bt_lane_en(bt_lane_en),
        .collect_done(collect_done),
        .c_result_valid(c_result_valid), .c_result(c_result),
        .c_result_index(c_result_index)
    );

    always @(*) begin
        cpu_rdata = cpu_rdata_w;
        cpu_ready = cpu_ready_w;
    end

endmodule
