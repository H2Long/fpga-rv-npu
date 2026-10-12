`timescale 1ns / 1ps
// ahb_lite_slave — ARM AHB-Lite 从机接口（NPU 唯一的 CPU 总线入口）
//
// 本模块把 AHB-Lite 的一次传输翻译成 NPU 内部的原生请求序列
// (req_addr/req_wdata/req_byte_en/req_we/req_valid)，下游的地址译码、
// control_regs、start_ctrl、buffer_access_ctrl 完全不需要知道 AHB 的存在。
// 原 mmio_if 已被本模块取代，NPU 不再保留私有 MMIO 总线。
//
// AHB-Lite 时序约定（改动前必须理解，否则会丢传输或协议违规）：
//   1. 一次传输分"地址阶段"和"数据阶段"，数据阶段紧跟在地址阶段之后。
//      本从机在地址阶段（HSEL && HTRANS[1] && HREADY_in 成立那一拍）锁存
//      地址，在下一拍（S_DATA，数据阶段）发出内部请求 req_valid。
//   2. 传输完成的那一拍（HREADYOUT=1）同时也是下一笔传输的地址阶段，所以
//      cap_now 分支必须在完成拍就地锁存下一笔的地址；漏掉这条会让背靠背
//      传输静默丢失（只执行第 1、3、5… 笔），这是自己写 AHB 从机最常见的错。
//   3. HREADYOUT=0 表示等待。寄存器访问和 Buffer 写是 0 等待（每拍一笔，
//      可背靠背流水）；Buffer 读因为 npu_ram 是同步读，要多等 1 拍。
//   4. 错误响应 HRESP=ERROR 必须持续两拍：第一拍 HREADYOUT=0，第二拍
//      HREADYOUT=1。只拉一拍 master 采不到（ARM AHB-Lite 协议要求）。
//   5. 复位期间 HREADYOUT 必须为 1、HRESP 必须为 OKAY。
//   6. HTRANS=IDLE/BUSY 不是传输；HBURST 不参与译码，INCR 突发的每个 beat
//      都会被当成一次独立传输正常处理。
//
// 地址：HADDR 减去 ADDR_BASE 之后才是 NPU 内部字地址。内部译码仍由 npu_top
// 完成（sel_ctrl/sel_status/sel_a_buf/sel_bt_buf/sel_c_buf），本模块不重复
// 定义地址映射，避免两处常量漂移。
//
// 错误响应条件（都要回 ERROR，不再静默忽略）：
//   a) 未映射地址：五个 sel 全为 0（原设计"读回 0、写忽略"是私有总线的将就
//      做法，在 AHB 上等于协议违规，软件写错地址永远发现不了）；
//   b) 非 32 位字访问：HSIZE != 3'b010 或 HADDR[1:0] != 0；
//   c) core_busy=1 期间访问 A/BT/C Buffer：原 buffer_access_ctrl 会把请求丢掉
//      但仍然应答成功，软件会以为数据写进去了。buffer_access_ctrl 的屏蔽
//      保留作为最后一道防线，本模块负责把错误如实报给 CPU。
// 错误路径比正常路径多 1 拍等待（译码结果在数据阶段才有效），不影响正常通路。
module ahb_lite_slave #(
    parameter [31:0] ADDR_BASE = 32'h4000_0000
)(
    input              HCLK,
    input              HRESETn,        // AHB 复位，低有效
    // ---- AHB-Lite 从机接口 ----
    input              HSEL,
    input       [31:0] HADDR,
    input       [1:0]  HTRANS,
    input              HWRITE,
    input       [2:0]  HSIZE,
    input       [31:0] HWDATA,         // 只在数据阶段有效
    input              HREADY_in,      // 互连回送的全局 HREADY
    output reg  [31:0] HRDATA,
    output reg         HREADYOUT,
    output reg  [1:0]  HRESP,
    // ---- NPU 运行状态 ----
    input              core_busy,      // 来自 tile_controller
    // ---- 下游原生请求（定义与旧 mmio_if 输出一致）----
    output reg  [31:0] req_addr,
    output reg  [31:0] req_wdata,
    output reg  [3:0]  req_byte_en,
    output reg         req_we,
    output reg         req_valid,      // 数据阶段单拍有效
    // ---- 来自 npu_top 的译码与读数据 ----
    input              sel_ctrl, sel_status,
    input              sel_a_buf, sel_bt_buf, sel_c_buf,
    input       [31:0] control_rdata, status_rdata, buffer_rdata
);

    localparam [1:0] HTRANS_IDLE   = 2'b00;
    localparam [1:0] HTRANS_BUSY   = 2'b01;
    localparam [1:0] HTRANS_NONSEQ = 2'b10;
    localparam [1:0] HTRANS_SEQ    = 2'b11;
    localparam [1:0] HRESP_OKAY    = 2'b00;
    localparam [1:0] HRESP_ERROR   = 2'b01;

    // 状态与转移：
    //   S_IDLE 等地址阶段 -> S_DATA；
    //   S_DATA 发请求：寄存器/Buffer 写当拍完成 -> 就地接下一笔或回 S_IDLE；
    //          Buffer 读 -> S_RDD（等同步 RAM 数据）；错误 -> S_ERR1；
    //   S_RDD 回数据并接下一笔；S_ERR1 -> S_ERR2；S_ERR2 接下一笔。
    localparam [2:0]
        S_IDLE = 3'd0,
        S_DATA = 3'd1,
        S_RDD  = 3'd2,
        S_ERR1 = 3'd3,
        S_ERR2 = 3'd4;

    reg [2:0]  state;
    reg [31:0] addr_q;      // 本笔传输的内部地址（已减基址）
    reg        write_q;
    reg        size_ok_q;   // 地址阶段采到的 HSIZE / 对齐检查结果

    reg        bus_phase;   // 本拍总线上是有效地址阶段
    reg        cap_now;     // 本拍接受下一笔地址
    reg        is_buf;
    reg        mapped;
    reg        err_now;
    reg [31:0] off_w;

    always @(*) begin
        off_w     = HADDR - ADDR_BASE;
        bus_phase = HSEL && ((HTRANS == HTRANS_NONSEQ) || (HTRANS == HTRANS_SEQ))
                    && HREADY_in;
        // 接受下一笔地址的条件：本拍自己的传输已经完成（HREADYOUT=1）且总线上
        // 是有效地址阶段。S_IDLE 下没有在途传输，同样成立。
        cap_now   = bus_phase && HREADYOUT;

        // 译码结果来自 addr_q，所以错误判断在数据阶段才有效。
        is_buf  = sel_a_buf || sel_bt_buf || sel_c_buf;
        mapped  = sel_ctrl || sel_status || is_buf;
        err_now = !mapped || !size_ok_q || (core_busy && is_buf);

        // ---- 下游原生请求 ----
        req_addr    = addr_q;
        req_wdata   = HWDATA;
        req_we      = write_q;
        req_byte_en = write_q ? 4'hF : 4'h0;
        req_valid   = (state == S_DATA);

        // ---- AHB 应答 ----
        HRDATA    = sel_ctrl   ? control_rdata :
                    sel_status ? status_rdata  : buffer_rdata;
        // HREADYOUT=0 只在两种场合：Buffer 读等同步 RAM 数据、错误响应的第 1 拍。
        // 空闲（S_IDLE）必须是 1，否则总线上永远不出现有效地址阶段。
        HREADYOUT = ((state == S_DATA) && (err_now || (is_buf && !write_q))) ? 1'b0 :
                    (state == S_ERR1) ? 1'b0 : 1'b1;
        HRESP     = ((state == S_ERR1) || (state == S_ERR2)) ? HRESP_ERROR : HRESP_OKAY;
    end

    always @(posedge HCLK) begin
        if (!HRESETn) begin
            state     <= S_IDLE;
            addr_q    <= 32'd0;
            write_q   <= 1'b0;
            size_ok_q <= 1'b0;
        end else begin
            // 完成拍就地锁存下一笔地址（见文件头第 2 条）
            if (cap_now) begin
                addr_q    <= off_w;
                write_q   <= HWRITE;
                size_ok_q <= (HSIZE == 3'b010) && (HADDR[1:0] == 2'd0);
            end
            case (state)
                S_IDLE: begin
                    state <= cap_now ? S_DATA : S_IDLE;
                end
                S_DATA: begin
                    if (err_now) begin
                        state <= S_ERR1;
                    end else if (is_buf && !write_q) begin
                        state <= S_RDD;      // 同步 RAM 读，数据下一拍回来
                    end else begin
                        state <= cap_now ? S_DATA : S_IDLE;
                    end
                end
                S_RDD: begin
                    state <= cap_now ? S_DATA : S_IDLE;
                end
                S_ERR1: begin
                    state <= S_ERR2;         // 错误响应第 1 拍结束
                end
                S_ERR2: begin
                    state <= cap_now ? S_DATA : S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
