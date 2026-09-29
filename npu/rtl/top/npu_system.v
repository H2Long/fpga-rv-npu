// npu_system — NPU 唯一系统顶层。
//
// 四个功能平面的边界固定在这里：
//   npu_top    处理 CPU MMIO、配置寄存器和 CPU/Buffer 访问仲裁；
//   npu_ctrl   处理 Tile 循环、地址生成、阵列时序和 C 写回；
//   npu_buffer 处理 A/BT/C RAM、预取 FIFO 和 C 写 FIFO；
//   npu_mac    处理 INT8 拆包、波前对齐、PE 阵列和结果收集。
// 控制:CPU -> npu_top -> npu_ctrl -> npu_mac
// 数据:A/BT Buffer -> FIFO -> npu_mac -> C 结果 FIFO -> C Buffer
//
// 控制:CPU -> npu_top -> npu_ctrl -> npu_mac
// A:   A Buffer -> A FIFO -> pair_stream_ctrl -> MAC
// BT:  BT Buffer -> BT FIFO -> pair_stream_ctrl -> MAC
// C:   MAC -> c_tile_acc_ctrl -> quantizer -> c_tile_write_ctrl -> C write FIFO -> C Buffer
`include "npu_defines.vh"

module npu_system(
    input  wire        clk,
    input  wire        rst_n,
    // CPU MMIO 总线
    input  wire [31:0] cpu_addr,
    input  wire [31:0] cpu_wdata,
    input  wire [3:0]  cpu_byte_en,
    input  wire        cpu_we,
    input  wire        cpu_valid,
    output wire [31:0] cpu_rdata,
    output wire        cpu_ready
);

    // npu_top 与 npu_ctrl 之间的任务级控制接口。
    wire        start_pulse;
    wire [`NPU_DIM_W-1:0]  cfg_m, cfg_n, cfg_k;
    wire [`NPU_TILE_W-1:0] cfg_tm, cfg_tn;
    wire [`NPU_TK_W-1:0]   cfg_tk;
    wire [`NPU_QS_W-1:0]   cfg_qshift;
    wire        core_busy, core_done;
    wire [`NPU_ERR_W-1:0]  error_code;

    // npu_top 与 npu_buffer 之间的 CPU 端口。
    // 只把 Buffer 实际可用状态送回 npu_top；npu_top 不再导出重复的 ready 信号。
    wire        cpu_a_we, cpu_a_re, cpu_bt_we, cpu_bt_re, cpu_c_we, cpu_c_re;
    wire [`NPU_ABUF_AW-1:0] cpu_a_addr;
    wire [`NPU_BBUF_AW-1:0] cpu_bt_addr;
    wire [`NPU_CBUF_AW-1:0] cpu_c_addr;
    wire [31:0] cpu_a_wdata, cpu_bt_wdata, cpu_c_wdata;
    wire [31:0] a_rdata_cpu, bt_rdata_cpu, c_rdata_cpu;
    wire        buffer_ready_buffer;

    // npu_ctrl 发起 A/BT 读请求，npu_buffer 返回同步 RAM 数据和 FIFO 状态。
    wire [`NPU_ABUF_AW-1:0] npu_a_addr;
    wire        npu_a_re;
    wire [`NPU_BBUF_AW-1:0] npu_bt_addr;
    wire        npu_bt_re;
    wire        a_fifo_valid, a_fifo_pop, bt_fifo_valid, bt_fifo_pop;
    wire [31:0] a_fifo_rdata, bt_fifo_rdata;
    wire [`NPU_FIFO_AW:0] a_fifo_count, bt_fifo_count;

    // npu_ctrl 到 npu_mac 的阵列控制、数据流和结果流。
    wire        array_start, array_enable, array_clear_acc, array_flush;
    wire        a_stream_valid, bt_stream_valid;
    wire [31:0] a_stream_data, bt_stream_data;
    wire [3:0]  a_lane_en, bt_lane_en;
    wire        a_stream_ready, bt_stream_ready;
    wire        array_done;
    wire        c_result_valid;
    wire [31:0] c_result;
    wire [3:0]  c_result_index;

    // npu_ctrl 到 npu_buffer 的 C 写回 FIFO 接口。
    wire        cwr_valid, cwr_ready, cwr_empty, c_wr_pulse;
    wire [`NPU_CBUF_AW-1:0] cwr_addr;
    wire [31:0] cwr_data;

    // ============ npu_top ============
    npu_top u_npu_top(
        .clk(clk), .rst_n(rst_n),
        .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata), .cpu_byte_en(cpu_byte_en),
        .cpu_we(cpu_we), .cpu_valid(cpu_valid),
        .cpu_rdata(cpu_rdata), .cpu_ready(cpu_ready),
        .start_pulse(start_pulse),
        .cfg_m(cfg_m), .cfg_n(cfg_n), .cfg_k(cfg_k),
        .cfg_tm(cfg_tm), .cfg_tn(cfg_tn), .cfg_tk(cfg_tk), .cfg_qshift(cfg_qshift),
        .core_busy(core_busy), .core_done(core_done), .error_code(error_code),
        .cpu_a_we(cpu_a_we), .cpu_a_re(cpu_a_re),
        .cpu_bt_we(cpu_bt_we), .cpu_bt_re(cpu_bt_re),
        .cpu_c_we(cpu_c_we), .cpu_c_re(cpu_c_re),
        .cpu_a_addr(cpu_a_addr), .cpu_bt_addr(cpu_bt_addr), .cpu_c_addr(cpu_c_addr),
        .cpu_a_wdata(cpu_a_wdata), .cpu_bt_wdata(cpu_bt_wdata), .cpu_c_wdata(cpu_c_wdata),
        .a_rdata_cpu(a_rdata_cpu), .bt_rdata_cpu(bt_rdata_cpu), .c_rdata_cpu(c_rdata_cpu),
        .buffer_ready_i(buffer_ready_buffer)
    );

    // ============ npu_ctrl ============
    npu_ctrl u_npu_ctrl(
        .clk(clk), .rst_n(rst_n),
        .start_pulse(start_pulse),
        .cfg_m(cfg_m), .cfg_n(cfg_n), .cfg_k(cfg_k),
        .cfg_tm(cfg_tm), .cfg_tn(cfg_tn), .cfg_tk(cfg_tk), .cfg_qshift(cfg_qshift),
        .a_addr(npu_a_addr), .a_re(npu_a_re),
        .bt_addr(npu_bt_addr), .bt_re(npu_bt_re),
        .a_fifo_valid(a_fifo_valid), .a_fifo_rdata(a_fifo_rdata),
        .a_fifo_count(a_fifo_count), .a_fifo_pop(a_fifo_pop),
        .bt_fifo_valid(bt_fifo_valid), .bt_fifo_rdata(bt_fifo_rdata),
        .bt_fifo_count(bt_fifo_count), .bt_fifo_pop(bt_fifo_pop),
        .array_start(array_start), .array_enable(array_enable),
        .array_clear_acc(array_clear_acc), .array_flush(array_flush),
        .a_stream_valid(a_stream_valid), .a_stream_data(a_stream_data),
        .bt_stream_valid(bt_stream_valid), .bt_stream_data(bt_stream_data),
        .a_lane_en(a_lane_en), .bt_lane_en(bt_lane_en),
        .a_stream_ready(a_stream_ready), .bt_stream_ready(bt_stream_ready),
        .array_done(array_done),
        .c_result_valid(c_result_valid), .c_result(c_result),
        .c_result_index(c_result_index),
        .cwr_valid(cwr_valid), .cwr_addr(cwr_addr), .cwr_data(cwr_data),
        .cwr_ready(cwr_ready), .cwr_empty(cwr_empty), .c_wr_pulse(c_wr_pulse),
        .core_busy(core_busy), .core_done(core_done), .error_code(error_code)
    );

    // ============ npu_buffer ============
    npu_buffer u_npu_buffer(
        .clk(clk), .rst_n(rst_n), .core_busy(core_busy),
        .cpu_a_we(cpu_a_we), .cpu_a_re(cpu_a_re), .cpu_a_addr(cpu_a_addr),
        .cpu_a_wdata(cpu_a_wdata),
        .cpu_bt_we(cpu_bt_we), .cpu_bt_re(cpu_bt_re), .cpu_bt_addr(cpu_bt_addr),
        .cpu_bt_wdata(cpu_bt_wdata),
        .cpu_c_we(cpu_c_we), .cpu_c_re(cpu_c_re), .cpu_c_addr(cpu_c_addr),
        .cpu_c_wdata(cpu_c_wdata),
        .npu_a_addr(npu_a_addr), .npu_a_re(npu_a_re),
        .npu_bt_addr(npu_bt_addr), .npu_bt_re(npu_bt_re),
        .a_rdata_cpu(a_rdata_cpu), .bt_rdata_cpu(bt_rdata_cpu), .c_rdata_cpu(c_rdata_cpu),
        .a_fifo_valid(a_fifo_valid), .a_fifo_rdata(a_fifo_rdata),
        .a_fifo_count(a_fifo_count), .a_fifo_pop(a_fifo_pop),
        .bt_fifo_valid(bt_fifo_valid), .bt_fifo_rdata(bt_fifo_rdata),
        .bt_fifo_count(bt_fifo_count), .bt_fifo_pop(bt_fifo_pop),
        .cwr_valid(cwr_valid), .cwr_addr(cwr_addr), .cwr_data(cwr_data),
        .cwr_ready(cwr_ready), .cwr_empty(cwr_empty), .c_wr_pulse(c_wr_pulse),
        .buffer_ready(buffer_ready_buffer)
    );

    // ============ npu_mac ============
    npu_mac u_npu_mac(
        .clk(clk), .rst_n(rst_n),
        .array_start(array_start), .array_enable(array_enable),
        .array_clear_acc(array_clear_acc), .array_flush(array_flush),
        .a_stream_valid(a_stream_valid), .a_stream_data(a_stream_data),
        .bt_stream_valid(bt_stream_valid), .bt_stream_data(bt_stream_data),
        .a_lane_en(a_lane_en), .bt_lane_en(bt_lane_en),
        .a_stream_ready(a_stream_ready), .bt_stream_ready(bt_stream_ready),
        .array_done(array_done),
        .c_result_valid(c_result_valid), .c_result(c_result),
        .c_result_index(c_result_index)
    );

endmodule
