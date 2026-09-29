// npu_buffer — 数据存储与搬运平面：A/BT/C RAM、NPU 读端口控制、
// 预取 FIFO 和 C 写 FIFO。
// RAM 端口归属:core_busy=1 时 A/BT 读端口归 NPU、C 写端口归写 FIFO;
//               core_busy=0 时全部归 CPU。
`include "npu_defines.vh"

module npu_buffer(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        core_busy,
    // CPU 侧端口(来自 npu_top.cpu_port_ctrl)
    input  wire        cpu_a_we,  cpu_a_re,
    input  wire [`NPU_ABUF_AW-1:0] cpu_a_addr,
    input  wire [31:0] cpu_a_wdata,
    input  wire        cpu_bt_we, cpu_bt_re,
    input  wire [`NPU_BBUF_AW-1:0] cpu_bt_addr,
    input  wire [31:0] cpu_bt_wdata,
    input  wire        cpu_c_we,  cpu_c_re,
    input  wire [`NPU_CBUF_AW-1:0] cpu_c_addr,
    input  wire [31:0] cpu_c_wdata,
    // NPU 读请求(来自 npu_ctrl)
    input  wire [`NPU_ABUF_AW-1:0] npu_a_addr,
    input  wire        npu_a_re,
    input  wire [`NPU_BBUF_AW-1:0] npu_bt_addr,
    input  wire        npu_bt_re,
    // CPU 读数据返回
    output wire [31:0] a_rdata_cpu, bt_rdata_cpu, c_rdata_cpu,
    // 预取 FIFO 接口(到 npu_ctrl)
    output wire        a_fifo_valid,
    output wire [31:0] a_fifo_rdata,
    output wire [`NPU_FIFO_AW:0] a_fifo_count,
    input  wire        a_fifo_pop,
    output wire        bt_fifo_valid,
    output wire [31:0] bt_fifo_rdata,
    output wire [`NPU_FIFO_AW:0] bt_fifo_count,
    input  wire        bt_fifo_pop,
    // C 写回(来自 npu_ctrl.c_tile_write_ctrl)
    input  wire        cwr_valid,
    input  wire [`NPU_CBUF_AW-1:0] cwr_addr,
    input  wire [31:0] cwr_data,
    output wire        cwr_ready, cwr_empty, c_wr_pulse,
    // 状态
    output wire        buffer_ready
);

    // A/BT 在运行期间由 NPU 读，空闲期间由 CPU 读写。
    // 写端口始终来自 CPU；core_busy=1 时 CPU 写请求在上游被禁止。
    // ---- A RAM 端口归属 ----
    wire [`NPU_ABUF_AW-1:0] a_ram_waddr = cpu_a_addr;
    wire                     a_ram_we    = cpu_a_we;
    wire [`NPU_ABUF_AW-1:0] a_ram_raddr = core_busy ? npu_a_addr : cpu_a_addr;
    wire                     a_ram_re    = core_busy ? npu_a_re    : cpu_a_re;
    wire [31:0]              a_ram_rdata;

    a_buffer u_a_buffer(
        .clk(clk),
        .we(a_ram_we), .waddr(a_ram_waddr), .wdata(cpu_a_wdata),
        .re(a_ram_re), .raddr(a_ram_raddr), .rdata(a_ram_rdata)
    );
    assign a_rdata_cpu = a_ram_rdata;

    // ---- BT RAM 端口归属 ----
    wire [`NPU_BBUF_AW-1:0] bt_ram_waddr = cpu_bt_addr;
    wire                     bt_ram_we    = cpu_bt_we;
    wire [`NPU_BBUF_AW-1:0] bt_ram_raddr = core_busy ? npu_bt_addr : cpu_bt_addr;
    wire                     bt_ram_re    = core_busy ? npu_bt_re    : cpu_bt_re;
    wire [31:0]              bt_ram_rdata;

    bt_buffer u_bt_buffer(
        .clk(clk),
        .we(bt_ram_we), .waddr(bt_ram_waddr), .wdata(cpu_bt_wdata),
        .re(bt_ram_re), .raddr(bt_ram_raddr), .rdata(bt_ram_rdata)
    );
    assign bt_rdata_cpu = bt_ram_rdata;

    // ---- C RAM 端口归属 ----
    wire [`NPU_CBUF_AW-1:0] cwf_addr;   // c_write_fifo -> C RAM
    wire                     cwf_we;
    wire [31:0]              cwf_data;

    wire [`NPU_CBUF_AW-1:0] c_ram_waddr = core_busy ? cwf_addr : cpu_c_addr;
    wire                     c_ram_we    = core_busy ? cwf_we    : cpu_c_we;
    wire [31:0]              c_ram_wdata = core_busy ? cwf_data  : cpu_c_wdata;
    wire [31:0]              c_ram_rdata;

    c_buffer u_c_buffer(
        .clk(clk),
        .we(c_ram_we), .waddr(c_ram_waddr), .wdata(c_ram_wdata),
        .re(cpu_c_re), .raddr(cpu_c_addr), .rdata(c_ram_rdata)
    );
    assign c_rdata_cpu = c_ram_rdata;

    // 同步 RAM 的读数据比 read enable 晚一拍返回，npu_read_port_ctrl
    // 将这个延迟后的 valid 与 RAM 数据一起送入预取 FIFO。
    // ---- NPU 读端口控制:同步读返回 -> FIFO ----
    wire a_fifo_push, bt_fifo_push;

    npu_read_port_ctrl u_npu_read_port_ctrl(
        .clk(clk), .rst_n(rst_n), .core_busy(core_busy),
        .a_re(npu_a_re),  .a_fifo_push(a_fifo_push),
        .bt_re(npu_bt_re), .bt_fifo_push(bt_fifo_push)
    );

    a_prefetch_fifo u_a_prefetch_fifo(
        .clk(clk), .rst_n(rst_n),
        .push(a_fifo_push), .wdata(a_ram_rdata), .pop(a_fifo_pop),
        .rdata(a_fifo_rdata), .valid(a_fifo_valid), .count(a_fifo_count)
    );

    bt_prefetch_fifo u_bt_prefetch_fifo(
        .clk(clk), .rst_n(rst_n),
        .push(bt_fifo_push), .wdata(bt_ram_rdata), .pop(bt_fifo_pop),
        .rdata(bt_fifo_rdata), .valid(bt_fifo_valid), .count(bt_fifo_count)
    );

    // C 写 FIFO 将结果写回和 C RAM 的实际写脉冲解耦；done_ctrl 统计 c_wr_pulse。
    // ---- C 写 FIFO ----
    c_write_fifo u_c_write_fifo(
        .clk(clk), .rst_n(rst_n), .core_busy(core_busy),
        .push(cwr_valid), .waddr(cwr_addr), .wdata(cwr_data),
        .ready(cwr_ready), .empty(cwr_empty),
        .ram_we(cwf_we), .ram_addr(cwf_addr), .ram_wdata(cwf_data),
        .c_wr_pulse(c_wr_pulse)
    );

    // Buffer 在 NPU 空闲时可供 CPU 访问，运行期间由 NPU 独占。
    assign buffer_ready = !core_busy;

endmodule
