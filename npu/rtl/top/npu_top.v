// npu_top — CPU 控制平面:MMIO 协议、地址译码、控制/状态寄存器、任务启动与访问仲裁
// 内含 7 个模块:mmio_if / addr_decoder / control_regs / status_regs /
//               start_ctrl / buffer_access_ctrl / cpu_port_ctrl
`include "npu_defines.vh"

module npu_top(
    input  wire        clk,
    input  wire        rst_n,
    // CPU MMIO 总线
    input  wire [31:0] cpu_addr,
    input  wire [31:0] cpu_wdata,
    input  wire [3:0]  cpu_byte_en,
    input  wire        cpu_we,
    input  wire        cpu_valid,
    output wire [31:0] cpu_rdata,
    output wire        cpu_ready,
    // 到 npu_ctrl(启动脉冲 + 锁存后的任务参数)
    output wire        start_pulse,
    output wire [`NPU_DIM_W-1:0]  cfg_m, cfg_n, cfg_k,
    output wire [`NPU_TILE_W-1:0] cfg_tm, cfg_tn,
    output wire [`NPU_TK_W-1:0]   cfg_tk,
    output wire [`NPU_QS_W-1:0]   cfg_qshift,
    // 来自 npu_ctrl
    input  wire        core_busy,
    input  wire        core_done,
    input  wire [`NPU_ERR_W-1:0]  error_code,
    // CPU 侧 RAM 端口(到 npu_buffer)
    output wire        cpu_a_we,  cpu_a_re,
    output wire        cpu_bt_we, cpu_bt_re,
    output wire        cpu_c_we,  cpu_c_re,
    output wire [`NPU_ABUF_AW-1:0] cpu_a_addr,
    output wire [`NPU_BBUF_AW-1:0] cpu_bt_addr,
    output wire [`NPU_CBUF_AW-1:0] cpu_c_addr,
    output wire [31:0] cpu_a_wdata, cpu_bt_wdata, cpu_c_wdata,
    input  wire [31:0] a_rdata_cpu, bt_rdata_cpu, c_rdata_cpu,
    // 状态
    input  wire        buffer_ready_i
);

    // ---- 内部连线 ----
    wire [31:0] req_addr, req_wdata;
    wire [3:0]  req_byte_en;
    wire        req_we, req_valid;
    wire        sel_ctrl, sel_status, sel_buffer;
    wire        sel_a_buf, sel_bt_buf, sel_c_buf;
    wire [`NPU_ABUF_AW-1:0] a_local_addr;
    wire [`NPU_BBUF_AW-1:0] bt_local_addr;
    wire [`NPU_CBUF_AW-1:0] c_local_addr;
    wire [2:0]  ctrl_reg_off;

    wire [31:0] control_rdata, status_rdata, buffer_rdata;

    // start_ctrl 的锁存参数
    wire [`NPU_DIM_W-1:0]  m_l, n_l, k_l;
    wire [`NPU_TILE_W-1:0] tm_l, tn_l;
    wire [`NPU_TK_W-1:0]   tk_l;
    wire [`NPU_QS_W-1:0]   qs_l;
    wire        busy_status, done_status;
    wire        start_req, clear_done_req;

    // cpu_port_ctrl 输出的 RAM 端口
    wire [`NPU_ABUF_AW-1:0] ram_a_addr;
    wire [`NPU_BBUF_AW-1:0] ram_bt_addr;
    wire [`NPU_CBUF_AW-1:0] ram_c_addr;
    wire        ram_a_we, ram_a_re, ram_bt_we, ram_bt_re, ram_c_we, ram_c_re;
    wire [31:0] ram_a_wdata, ram_bt_wdata, ram_c_wdata;

    // buffer_access_ctrl -> cpu_port_ctrl 的数据/字节使能
    wire [31:0] cpu_buf_wdata;
    wire [3:0]  cpu_buf_byte_en;

    // cpu_port_ctrl 输出的(按字节使能屏蔽后的)写数据桥接到对外 RAM 端口
    assign cpu_a_wdata  = ram_a_wdata;
    assign cpu_bt_wdata = ram_bt_wdata;
    assign cpu_c_wdata  = ram_c_wdata;

    // ---- mmio_if ----
    mmio_if u_mmio_if(
        .clk(clk), .rst_n(rst_n),
        .cpu_valid(cpu_valid), .cpu_we(cpu_we),
        .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata), .cpu_byte_en(cpu_byte_en),
        .cpu_ready(cpu_ready), .cpu_rdata(cpu_rdata),
        .req_addr(req_addr), .req_wdata(req_wdata),
        .req_byte_en(req_byte_en), .req_we(req_we), .req_valid(req_valid),
        .sel_ctrl(sel_ctrl), .sel_status(sel_status), .sel_buffer(sel_buffer),
        .control_rdata(control_rdata), .status_rdata(status_rdata),
        .buffer_rdata(buffer_rdata)
    );

    // ---- addr_decoder(对锁存地址组合译码) ----
    addr_decoder u_addr_decoder(
        .req_addr(req_addr),
        .sel_ctrl(sel_ctrl), .sel_status(sel_status), .sel_buffer(sel_buffer),
        .sel_a_buf(sel_a_buf), .sel_bt_buf(sel_bt_buf), .sel_c_buf(sel_c_buf),
        .a_local_addr(a_local_addr), .bt_local_addr(bt_local_addr),
        .c_local_addr(c_local_addr), .ctrl_reg_off(ctrl_reg_off)
    );

    // control_regs 的实时配置值(仅供 start_ctrl 在启动瞬间采样)
    wire [`NPU_DIM_W-1:0]  cr_m, cr_n, cr_k;
    wire [`NPU_TILE_W-1:0] cr_tm, cr_tn;
    wire [`NPU_TK_W-1:0]   cr_tk;
    wire [`NPU_QS_W-1:0]   cr_qs;

    // ---- control_regs ----
    control_regs u_control_regs(
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_we(req_we), .sel_ctrl(sel_ctrl),
        .ctrl_reg_off(ctrl_reg_off), .req_wdata(req_wdata),
        .req_byte_en(req_byte_en),
        .cfg_m(cr_m), .cfg_n(cr_n), .cfg_k(cr_k),
        .cfg_tm(cr_tm), .cfg_tn(cr_tn), .cfg_tk(cr_tk), .cfg_qshift(cr_qs),
        .start_req(start_req), .clear_done_req(clear_done_req),
        .control_rdata(control_rdata)
    );

    // ---- status_regs ----
    status_regs u_status_regs(
        .req_we(req_we),
        .ctrl_reg_off(ctrl_reg_off),
        .busy_i(busy_status), .done_i(done_status),
        .error_i(error_code != `NPU_ERR_NONE),
        .buffer_ready_i(buffer_ready_i),
        .error_code_i(error_code),
        .status_rdata(status_rdata)
    );

    // ---- start_ctrl ----
    start_ctrl u_start_ctrl(
        .clk(clk), .rst_n(rst_n),
        .start_req(start_req), .clear_done_req(clear_done_req),
        .cfg_m(cr_m), .cfg_n(cr_n), .cfg_k(cr_k),
        .cfg_tm(cr_tm), .cfg_tn(cr_tn), .cfg_tk(cr_tk), .cfg_qshift(cr_qs),
        .core_done_i(core_done),
        .start_pulse(start_pulse),
        .m_l(m_l), .n_l(n_l), .k_l(k_l), .tm_l(tm_l), .tn_l(tn_l),
        .tk_l(tk_l), .qs_l(qs_l),
        .busy_status(busy_status), .done_status(done_status)
    );

    // 对 npu_ctrl 输出锁存后的任务参数(运行期间软件改动不影响当前任务)
    assign cfg_m = m_l;  assign cfg_n = n_l;  assign cfg_k = k_l;
    assign cfg_tm = tm_l; assign cfg_tn = tn_l;
    assign cfg_tk = tk_l; assign cfg_qshift = qs_l;

    // ---- buffer_access_ctrl ----
    buffer_access_ctrl u_buffer_access_ctrl(
        .clk(clk), .rst_n(rst_n),
        .req_valid(req_valid), .req_we(req_we), .req_byte_en(req_byte_en),
        .sel_a_buf(sel_a_buf), .sel_bt_buf(sel_bt_buf), .sel_c_buf(sel_c_buf),
        .a_local_addr(a_local_addr), .bt_local_addr(bt_local_addr),
        .c_local_addr(c_local_addr), .req_wdata(req_wdata),
        .core_busy(core_busy),
        .cpu_a_we(cpu_a_we), .cpu_a_re(cpu_a_re),
        .cpu_bt_we(cpu_bt_we), .cpu_bt_re(cpu_bt_re),
        .cpu_c_we(cpu_c_we), .cpu_c_re(cpu_c_re),
        .cpu_a_addr(cpu_a_addr), .cpu_bt_addr(cpu_bt_addr), .cpu_c_addr(cpu_c_addr),
        .cpu_buf_wdata(cpu_buf_wdata), .cpu_buf_byte_en(cpu_buf_byte_en),
        .a_rdata_cpu(a_rdata_cpu), .bt_rdata_cpu(bt_rdata_cpu),
        .c_rdata_cpu(c_rdata_cpu), .buffer_rdata(buffer_rdata)
    );

    // ---- cpu_port_ctrl ----
    cpu_port_ctrl u_cpu_port_ctrl(
        .clk(clk), .rst_n(rst_n),
        .cpu_a_we(cpu_a_we), .cpu_a_re(cpu_a_re),
        .cpu_bt_we(cpu_bt_we), .cpu_bt_re(cpu_bt_re),
        .cpu_c_we(cpu_c_we), .cpu_c_re(cpu_c_re),
        .cpu_a_addr(cpu_a_addr), .cpu_bt_addr(cpu_bt_addr), .cpu_c_addr(cpu_c_addr),
        .cpu_buf_wdata(cpu_buf_wdata), .cpu_buf_byte_en(cpu_buf_byte_en),
        .ram_a_addr(ram_a_addr), .ram_bt_addr(ram_bt_addr), .ram_c_addr(ram_c_addr),
        .ram_a_we(ram_a_we), .ram_a_re(ram_a_re),
        .ram_bt_we(ram_bt_we), .ram_bt_re(ram_bt_re),
        .ram_c_we(ram_c_we), .ram_c_re(ram_c_re),
        .ram_a_wdata(ram_a_wdata), .ram_bt_wdata(ram_bt_wdata), .ram_c_wdata(ram_c_wdata)
    );

endmodule
