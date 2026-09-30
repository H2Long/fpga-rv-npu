`timescale 1ns / 1ps
// tile_controller — Tile 调度、地址生成、搬运和 C 写回控制
//
// 本模块不保存矩阵数据，只负责把一次 GEMM 拆成 Tile 并把硬件推动起来：
//   参数使用 -> Tile 选择 -> A/BT 预取 -> 阵列喂数 -> 最后一个 K Tile 后排空一次
//   -> 结果快照与 C 写回（与下一个输出 Tile 的计算并行）
//
// 三条关键设计（决定了性能，改动前先读这里）：
//   1. K Tile 之间不清累加器、不排空阵列。阵列在预取期间整体冻结，整条 skew
//      管线一起保持偏移，所以跨 K Tile 的部分和留在 PE 累加器里连续累加。
//      TK 因此只是延迟/面积参数，不再是"每个 K Tile 付一次排空+搬回"的性能开销。
//   2. 预取与喂数重叠：喂第 k 个 K Tile 时用 pf_next_start 启动第 k+1 个的突发，
//      预取延迟被喂数覆盖；FIFO 深度足够容纳两段，不会溢出丢弃。
//   3. 结果不回阵列外累加：排空时把 16 个累加器整块快照给 c_tile_write_ctrl，
//      写回在后台完成，状态机直接进入下一个 Tile。core_done 等所有 C 真正落 RAM。
//
// 数据布局：A/BT 按 K 主序，第 (tile_i*K + tile_k*TK + k) 个字装第
// tile_i*4..tile_i*4+3 行（BT 为列）在第 k 步的 4 个 INT8。地址单位是 32 位字。
`include "npu_defines.vh"

module tile_controller(
    input        clk,
    input        rst,
    // 来自 npu_top：启动脉冲 + 锁存后的任务参数
    input        start_pulse,
    input [`NPU_DIM_W-1:0]  cfg_m, cfg_n, cfg_k,
    input [`NPU_TK_W-1:0]   cfg_tk,
    input [`NPU_QS_W-1:0]   cfg_qshift,
    // A/BT RAM 读请求（npu_buffer 内部同步读，数据下一次返回）
    output reg [`NPU_ABUF_AW-1:0] a_addr,
    output reg   a_re,
    output reg [`NPU_BBUF_AW-1:0] bt_addr,
    output reg   bt_re,
    // 预取 FIFO 接口
    input [31:0] a_fifo_rdata, bt_fifo_rdata,
    input [`NPU_FIFO_AW:0] a_fifo_count, bt_fifo_count,
    output reg   fifo_pair_pop,
    // 到 npu_mac
    output reg   acc_clear,
    output reg   array_enable,
    output reg   drain_en,
    output reg   stream_valid,
    output reg [31:0] a_stream_data, bt_stream_data,
    output reg [3:0]  a_lane_en, bt_lane_en,
    input [`NPU_PE_NUM*`NPU_ACC_W-1:0] acc_flat_in,
    input        drain_done,
    // C 写回（到 npu_buffer.c_write_fifo）
    output reg   cwr_valid,
    output reg [`NPU_CBUF_AW-1:0] cwr_addr,
    output reg [31:0] cwr_data,
    input        cwr_ready, cwr_empty, c_wr_pulse,
    // 状态（到 npu_top / systolic_fsm）
    output reg   core_busy,
    output reg   core_done
);

    integer b;

    // 组合直出的中间信号（规范要求写在 always @(*) 里，不用 assign）
    reg pair_fire;
    reg stream_start;
    reg [`NPU_ABUF_AW-1:0] a_pf_base;
    reg [`NPU_BBUF_AW-1:0] bt_pf_base;
    reg [`NPU_TK_W-1:0]    pf_len;
    reg [11:0] wr_cnt_next;

    // ---- 任务参数（start_ctrl 已经锁存，这里直接复用同一份快照）----
    wire [`NPU_DIM_W-1:0] lb_m = cfg_m;
    wire [`NPU_DIM_W-1:0] lb_n = cfg_n;
    wire [`NPU_DIM_W-1:0] lb_k = cfg_k;
    wire [`NPU_TK_W-1:0]  lb_tk = cfg_tk;
    wire [`NPU_QS_W-1:0]  lb_qs = cfg_qshift;
    wire [`NPU_TILE_W-1:0] lp_tm = `NPU_TM_TN;
    wire [`NPU_TILE_W-1:0] lp_tn = `NPU_TM_TN;

    // ---- 三层 Tile 计数器 ----
    reg [`NPU_TIDX_W-1:0] tile_i, tile_j, tile_k;
    wire sched_init, next_k_req, next_out_req;

    wire [`NPU_TIDX_W-1:0] nt_i = (lb_m + lp_tm - 1) / lp_tm;
    wire [`NPU_TIDX_W-1:0] nt_j = (lb_n + lp_tn - 1) / lp_tn;
    wire [`NPU_TIDX_W-1:0] nt_k = (lb_k + lb_tk - 1) / lb_tk;

    wire [`NPU_DIM_W-1:0] rem_m = lb_m - tile_i * lp_tm;
    wire [`NPU_DIM_W-1:0] rem_n = lb_n - tile_j * lp_tn;
    wire [`NPU_DIM_W-1:0] rem_k = lb_k - tile_k * lb_tk;

    // 下一个 K Tile 的长度。只在确实存在下一个 K Tile（!last_k_tile）时被使用，
    // 所以 lb_k - (tile_k+1)*lb_tk 不会下溢到有用的判断里。
    wire [`NPU_DIM_W-1:0] rem_k_next = lb_k - (tile_k + 6'd1) * lb_tk;
    wire [`NPU_TK_W-1:0]  valid_tk_next = (rem_k_next > {1'b0, lb_tk}) ?
                                          lb_tk : rem_k_next[`NPU_TK_W-1:0];

    reg last_k_tile, last_out_tile;
    reg [`NPU_TILE_W-1:0] valid_tm, valid_tn;
    reg [`NPU_TK_W-1:0]   valid_tk;

    always @(posedge clk) begin
        if (rst) begin
            tile_i <= {`NPU_TIDX_W{1'b0}};
            tile_j <= {`NPU_TIDX_W{1'b0}};
            tile_k <= {`NPU_TIDX_W{1'b0}};
        end else if (sched_init) begin
            tile_i <= {`NPU_TIDX_W{1'b0}};
            tile_j <= {`NPU_TIDX_W{1'b0}};
            tile_k <= {`NPU_TIDX_W{1'b0}};
        end else if (next_k_req) begin
            tile_k <= tile_k + 6'd1;
        end else if (next_out_req) begin
            tile_k <= {`NPU_TIDX_W{1'b0}};
            if (tile_j + 6'd1 >= nt_j) begin
                tile_j <= {`NPU_TIDX_W{1'b0}};
                tile_i <= tile_i + 6'd1;
            end else begin
                tile_j <= tile_j + 6'd1;
            end
        end
    end

    always @(*) begin
        last_k_tile      = (tile_k + 6'd1 >= nt_k);
        last_out_tile    = (tile_i + 6'd1 >= nt_i) && (tile_j + 6'd1 >= nt_j);
        valid_tm         = (rem_m > {3'd0, lp_tm}) ? lp_tm : rem_m[`NPU_TILE_W-1:0];
        valid_tn         = (rem_n > {3'd0, lp_tn}) ? lp_tn : rem_n[`NPU_TILE_W-1:0];
        valid_tk         = (rem_k > {1'b0, lb_tk}) ? lb_tk : rem_k[`NPU_TK_W-1:0];
    end

    // ---- Tile 基地址（内部字地址）----
    wire [`NPU_DIM_W+`NPU_DIM_W-1:0] a_word_off      = tile_i * lb_k + tile_k * lb_tk;
    wire [`NPU_DIM_W+`NPU_DIM_W-1:0] bt_word_off     = tile_j * lb_k + tile_k * lb_tk;
    wire [`NPU_DIM_W+`NPU_DIM_W-1:0] a_word_off_next = tile_i * lb_k + (tile_k + 6'd1) * lb_tk;
    wire [`NPU_DIM_W+`NPU_DIM_W-1:0] bt_word_off_next = tile_j * lb_k + (tile_k + 6'd1) * lb_tk;

    wire [`NPU_ABUF_AW-1:0] a_base      = a_word_off[`NPU_ABUF_AW-1:0];
    wire [`NPU_BBUF_AW-1:0] bt_base     = bt_word_off[`NPU_BBUF_AW-1:0];
    wire [`NPU_ABUF_AW-1:0] a_base_next = a_word_off_next[`NPU_ABUF_AW-1:0];
    wire [`NPU_BBUF_AW-1:0] bt_base_next = bt_word_off_next[`NPU_BBUF_AW-1:0];
    wire [`NPU_CBASE_W-1:0] c_base = (tile_i * lp_tm) * lb_n + tile_j * lp_tn;

    // ---- 主状态机 ----
    wire fsm_acc_clear, fsm_drain_en, fsm_array_enable, fsm_core_busy;
    wire pf_start, pf_next_start, feed_go, fsm_done, cwr_idle;

    systolic_fsm u_systolic_fsm(
        .clk(clk), .rst(rst),
        .start_pulse(start_pulse),
        .core_done(core_done),
        .last_k_tile(last_k_tile),
        .last_out_tile(last_out_tile),
        .valid_tk(valid_tk),
        .a_fifo_count(a_fifo_count), .bt_fifo_count(bt_fifo_count),
        .pair_fire(pair_fire),
        .drain_done(drain_done),
        .cwr_idle(cwr_idle),
        .sched_init(sched_init), .next_k_req(next_k_req), .next_out_req(next_out_req),
        .acc_clear(fsm_acc_clear),
        .pf_start(pf_start), .pf_next_start(pf_next_start),
        .feed_go(feed_go), .drain_en(fsm_drain_en), .array_enable(fsm_array_enable),
        .fsm_done(fsm_done), .core_busy(fsm_core_busy)
    );

    // ---- A/BT 预取：一次突发取完一个 K Tile ----
    wire [`NPU_ABUF_AW-1:0] a_rd_addr_w;
    wire [`NPU_BBUF_AW-1:0] bt_rd_addr_w;
    wire a_rd_re_w, bt_rd_re_w, a_burst_busy, bt_burst_busy;

    npu_stream_ctrl #(.AW(`NPU_ABUF_AW)) u_a_stream_ctrl(
        .clk(clk), .rst(rst),
        .base_in(a_pf_base), .len_in(pf_len), .start_in(stream_start),
        .rd_addr_out(a_rd_addr_w), .rd_re_out(a_rd_re_w), .busy_out(a_burst_busy)
    );

    npu_stream_ctrl #(.AW(`NPU_BBUF_AW)) u_bt_stream_ctrl(
        .clk(clk), .rst(rst),
        .base_in(bt_pf_base), .len_in(pf_len), .start_in(stream_start),
        .rd_addr_out(bt_rd_addr_w), .rd_re_out(bt_rd_re_w), .busy_out(bt_burst_busy)
    );

    // ---- 成对送数：两个 FIFO 都非空才出队（在下面的组合块里计算）----

    // ---- C Tile 快照 -> 量化 -> 写回 ----
    wire [31:0] cwr_data_w;
    wire [`NPU_CBUF_AW-1:0] cwr_addr_w;
    wire cwr_valid_w;

    c_tile_write_ctrl u_c_tile_write_ctrl(
        .clk(clk), .rst(rst),
        .acc_flat_in(acc_flat_in), .snap_valid_in(drain_done),
        .c_base_in(c_base), .n_dim_in(lb_n),
        .valid_tm_in(valid_tm), .valid_tn_in(valid_tn),
        .qshift_in(lb_qs),
        .cwr_ready_in(cwr_ready), .cwr_empty_in(cwr_empty),
        .cwr_valid_out(cwr_valid_w), .cwr_addr_out(cwr_addr_w), .cwr_data_out(cwr_data_w),
        .idle_out(cwr_idle)
    );

    // ---- 完成计数：只有真正写进 C RAM 的笔数才算完成 ----
    localparam TOTAL_W = 12;
    wire [TOTAL_W-1:0] total_w = lb_m * lb_n;   // 配置校验保证 <= NPU_CBUF_WORDS
    reg [TOTAL_W-1:0] wr_cnt;
    reg done_seen;
    reg core_done_w;

    always @(posedge clk) begin
        if (rst) begin
            wr_cnt      <= {TOTAL_W{1'b0}};
            done_seen   <= 1'b0;
            core_done_w <= 1'b0;
        end else begin
            core_done_w <= 1'b0;
            if (start_pulse) begin
                wr_cnt    <= {TOTAL_W{1'b0}};
                done_seen <= 1'b0;
            end else begin
                wr_cnt <= wr_cnt_next;
                // 全部 C 元素都写进 RAM 且写回通路空闲，才算任务完成。
                if (!done_seen && fsm_done && (wr_cnt_next >= total_w) && cwr_idle) begin
                    core_done_w <= 1'b1;
                    done_seen   <= 1'b1;
                end
            end
        end
    end

    always @(*) begin
        // 成对送数：两个 FIFO 都非空才出队
        pair_fire     = feed_go && (a_fifo_count != 0) && (bt_fifo_count != 0);
        fifo_pair_pop = pair_fire;

        // 预取突发：pf_start 与 pf_next_start 互斥。前者在换输出 Tile 时启动
        // 当前 K Tile 的预取，后者在进入喂数时启动下一个 K Tile 的预取。
        stream_start = pf_start || pf_next_start;
        a_pf_base    = pf_next_start ? a_base_next  : a_base;
        bt_pf_base   = pf_next_start ? bt_base_next : bt_base;
        pf_len       = pf_next_start ? valid_tk_next : valid_tk;

        wr_cnt_next = wr_cnt + {{(11){1'b0}}, c_wr_pulse};

        a_addr         = a_rd_addr_w;
        a_re           = a_rd_re_w;
        bt_addr        = bt_rd_addr_w;
        bt_re          = bt_rd_re_w;
        acc_clear      = fsm_acc_clear;
        drain_en       = fsm_drain_en;
        array_enable   = fsm_array_enable;
        core_busy      = fsm_core_busy;
        stream_valid   = pair_fire;
        a_stream_data  = a_fifo_rdata;
        bt_stream_data = bt_fifo_rdata;
        cwr_valid      = cwr_valid_w;
        cwr_addr       = cwr_addr_w;
        cwr_data       = cwr_data_w;
        core_done      = core_done_w;

        // 边界 Tile：valid_tm 行 / valid_tn 列以内的 lane 才有效，
        // 越界 lane 在 npu_mac 侧被补零，越界的 C 元素不会被写回。
        a_lane_en  = {4{1'b0}};
        bt_lane_en = {4{1'b0}};
        for (b = 0; b < `NPU_P; b = b + 1)
            a_lane_en[b] = (valid_tm > b);
        for (b = 0; b < `NPU_Q; b = b + 1)
            bt_lane_en[b] = (valid_tn > b);
    end

endmodule
