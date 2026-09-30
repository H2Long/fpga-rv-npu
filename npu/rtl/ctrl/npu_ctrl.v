`timescale 1ns / 1ps
// npu_ctrl — NPU 调度中心。
//
// 本模块不保存矩阵数据，只负责把一次 GEMM 拆成 Tile，并按以下顺序推动硬件：
// 参数锁存 -> 配置检查 -> Tile 选择 -> A/BT 预取 -> 阵列喂数/排空
// -> C partial-sum 累加 -> 量化和写回 -> 统计完成。
// 通过 start_pulse 锁存后的参数在整个任务期间保持不变。
`include "npu_defines.vh"

module npu_ctrl(
    input        clk,
    input        rst,
    // 来自 npu_top:start_pulse + 锁存后的任务参数
    input        start_pulse,
    input [`NPU_DIM_W-1:0]  cfg_m, cfg_n, cfg_k,
    input [`NPU_TILE_W-1:0] cfg_tm, cfg_tn,
    input [`NPU_TK_W-1:0]   cfg_tk,
    input [`NPU_QS_W-1:0]   cfg_qshift,
    // A/BT RAM 读请求(经 npu_buffer 内部同步读延迟)
    output reg [`NPU_ABUF_AW-1:0] a_addr,
    output reg        a_re,
    output reg [`NPU_BBUF_AW-1:0] bt_addr,
    output reg        bt_re,
    // 预取 FIFO 接口(来自 npu_buffer)
    input        a_fifo_valid,
    input [31:0] a_fifo_rdata,
    input [`NPU_FIFO_AW:0] a_fifo_count,
    output reg        a_fifo_pop,
    input        bt_fifo_valid,
    input [31:0] bt_fifo_rdata,
    input [`NPU_FIFO_AW:0] bt_fifo_count,
    output reg        bt_fifo_pop,
    // 到 npu_mac
    output reg        array_start, array_enable, array_clear_acc,
    output reg        array_flush,
    output reg        a_stream_valid,
    output reg [31:0] a_stream_data,
    output reg        bt_stream_valid,
    output reg [31:0] bt_stream_data,
    output reg [3:0]  a_lane_en, bt_lane_en,
    input        a_stream_ready,
    input        bt_stream_ready,
    input        array_done,
    input        c_result_valid,
    input [31:0] c_result,
    input [3:0]  c_result_index,
    // C 写回(到 npu_buffer.c_write_fifo)
    output reg        cwr_valid,
    output reg [`NPU_CBUF_AW-1:0] cwr_addr,
    output reg [31:0] cwr_data,
    input        cwr_ready, cwr_empty, c_wr_pulse,
    // 状态(到 npu_top)
    output reg        core_busy,
    output reg        core_done,
    output reg [`NPU_ERR_W-1:0] error_code
);

    wire [`NPU_ABUF_AW-1:0] a_addr_w;
    wire a_re_w;
    wire [`NPU_BBUF_AW-1:0] bt_addr_w;
    wire bt_re_w;
    wire a_fifo_pop_w, bt_fifo_pop_w;
    wire array_start_w, array_enable_w, array_clear_acc_w, array_flush_w;
    wire a_stream_valid_w, bt_stream_valid_w;
    wire [31:0] a_stream_data_w, bt_stream_data_w;
    wire [`NPU_CBUF_AW-1:0] cwr_addr_w;
    wire cwr_valid_w;
    wire [31:0] cwr_data_w;
    wire core_busy_w, core_done_w;
    wire [`NPU_ERR_W-1:0] error_code_w;

    // npu_top/start_ctrl 已经在 start_pulse 前锁存任务参数，这里直接复用
    // 该快照，避免控制面再次复制一组参数寄存器。
    wire [`NPU_DIM_W-1:0]  lp_m = cfg_m;
    wire [`NPU_DIM_W-1:0]  lp_n = cfg_n;
    wire [`NPU_DIM_W-1:0]  lp_k = cfg_k;
    wire [`NPU_TILE_W-1:0] lp_tm = cfg_tm;
    wire [`NPU_TILE_W-1:0] lp_tn = cfg_tn;
    wire [`NPU_TK_W-1:0]   lp_tk = cfg_tk;
    wire [`NPU_QS_W-1:0]   lp_qs = cfg_qshift;

    // ---- 配置检查 ----
    reg cfg_ok;
    reg [`NPU_ERR_W-1:0] chk_err_code;
    integer a_words, bt_words, c_words;

    // 配置检查只在启动前被 FSM 使用，直接放在调度中心，避免一个只含
    // 组合逻辑的层级模块。
    always @(*) begin
        a_words  = 0;
        bt_words = 0;
        c_words  = lp_m * lp_n;
        if (lp_tm != 0)
            a_words = ((lp_m + lp_tm - 1) / lp_tm) * lp_k;
        if (lp_tn != 0)
            bt_words = ((lp_n + lp_tn - 1) / lp_tn) * lp_k;

        cfg_ok = 1'b1;
        chk_err_code = `NPU_ERR_NONE;
        if (lp_m == 0 || lp_n == 0 || lp_k == 0) begin
            cfg_ok = 1'b0;
            chk_err_code = `NPU_ERR_DIM_ZERO;
        end else if (lp_tm == 0 || lp_tn == 0 ||
                     lp_tm > `NPU_P || lp_tn > `NPU_Q) begin
            cfg_ok = 1'b0;
            chk_err_code = `NPU_ERR_TILE_GT_ARRAY;
        end else if (lp_tk == 0 || lp_tk > lp_k ||
                     lp_tk > (1 << `NPU_FIFO_AW)) begin
            cfg_ok = 1'b0;
            chk_err_code = `NPU_ERR_TK_INVALID;
        end else if (a_words > (1 << `NPU_ABUF_AW) ||
                     bt_words > (1 << `NPU_BBUF_AW) ||
                     c_words > (1 << `NPU_CBUF_AW)) begin
            cfg_ok = 1'b0;
            chk_err_code = `NPU_ERR_BUF_OVERFLOW;
        end
    end

    // ---- tile 调度与状态 ----
    wire [`NPU_TIDX_W-1:0] tile_i, tile_j, tile_k;
    wire sched_init, next_k_req, next_out_req;

    tile_scheduler u_tile_scheduler(
        .clk(clk), .rst(rst),
        .sched_init(sched_init), .next_k_req(next_k_req), .next_out_req(next_out_req),
        .lp_m(lp_m), .lp_n(lp_n), .lp_k(lp_k),
        .lp_tm(lp_tm), .lp_tn(lp_tn), .lp_tk(lp_tk),
        .tile_i(tile_i), .tile_j(tile_j), .tile_k(tile_k)
    );

    reg first_k_tile, last_k_tile, last_output_tile;
    reg [`NPU_TILE_W-1:0] valid_tm, valid_tn;
    reg [`NPU_TK_W-1:0]   valid_tk;
    wire [`NPU_TIDX_W-1:0] nt_i = (lp_tm == 0) ? {`NPU_TIDX_W{1'b0}} :
                                   (lp_m + lp_tm - 1) / lp_tm;
    wire [`NPU_TIDX_W-1:0] nt_j = (lp_tn == 0) ? {`NPU_TIDX_W{1'b0}} :
                                   (lp_n + lp_tn - 1) / lp_tn;
    wire [`NPU_TIDX_W-1:0] nt_k = (lp_tk == 0) ? {`NPU_TIDX_W{1'b0}} :
                                   (lp_k + lp_tk - 1) / lp_tk;
    wire [`NPU_DIM_W-1:0] rem_m = lp_m - tile_i * lp_tm;
    wire [`NPU_DIM_W-1:0] rem_n = lp_n - tile_j * lp_tn;
    wire [`NPU_DIM_W-1:0] rem_k = lp_k - tile_k * lp_tk;

    always @(*) begin
        first_k_tile     = (tile_k == 5'd0);
        last_k_tile      = (tile_k + 5'd1 >= nt_k);
        last_output_tile = (tile_i + 5'd1 >= nt_i) &&
                           (tile_j + 5'd1 >= nt_j);
        valid_tm = (rem_m > {3'd0, lp_tm}) ? lp_tm : rem_m[`NPU_TILE_W-1:0];
        valid_tn = (rem_n > {3'd0, lp_tn}) ? lp_tn : rem_n[`NPU_TILE_W-1:0];
        valid_tk = (rem_k > {1'b0, lp_tk}) ? lp_tk : rem_k[`NPU_TK_W-1:0];
    end

    // ---- tile 基地址 ----
    wire [`NPU_ABUF_AW-1:0] a_base = tile_i * lp_k + tile_k * lp_tk;
    wire [`NPU_BBUF_AW-1:0] bt_base = tile_j * lp_k + tile_k * lp_tk;
    wire [`NPU_CBASE_W-1:0] c_base = (tile_i * lp_tm) * lp_n + tile_j * lp_tn;

    // ---- 主状态机 ----
    // acc_tile_clear 必须在每个输出 Tile 开始时产生，不能只依赖 first_k_tile，
    // 因为切换 tile_i/tile_j 时也需要清除上一块 C 的部分和。
    wire prefetch_go, ph_array_start, feed_go, drain_en, write_go;
    wire fsm_done, err_abort;
    wire pair_fire;
    wire write_done;               // c_tile_write_ctrl 完成
    wire acc_tile_clear;

    systolic_fsm u_systolic_fsm(
        .clk(clk), .rst(rst),
        .start_pulse(start_pulse), .cfg_ok(cfg_ok), .chk_err_code(chk_err_code),
        .core_done(core_done),
        .first_k_tile(first_k_tile), .last_k_tile(last_k_tile),
        .last_output_tile(last_output_tile), .valid_tk(valid_tk),
        .a_fifo_count(a_fifo_count), .bt_fifo_count(bt_fifo_count),
        .pair_fire(pair_fire), .array_done(array_done), .write_done(write_done),
        .sched_init(sched_init), .next_k_req(next_k_req), .next_out_req(next_out_req),
        .acc_tile_clear(acc_tile_clear), .prefetch_go(prefetch_go),
        .ph_array_start(ph_array_start), .feed_go(feed_go), .drain_en(drain_en),
        .write_go(write_go),
        .fsm_done(fsm_done), .err_abort(err_abort),
        .error_code(error_code_w), .core_busy(core_busy_w)
    );

    // ---- A/BT 读流控制 ----
    npu_stream_ctrl u_a_stream_ctrl(
        .clk(clk), .rst(rst),
        .base(a_base), .len(valid_tk), .go(prefetch_go),
        .rd_addr(a_addr_w), .rd_re(a_re_w)
    );

    npu_stream_ctrl u_bt_stream_ctrl(
        .clk(clk), .rst(rst),
        .base(bt_base), .len(valid_tk), .go(prefetch_go),
        .rd_addr(bt_addr_w), .rd_re(bt_re_w)
    );

    // ---- 成对送数 ----
    pair_stream_ctrl u_pair_stream_ctrl(
        .feed_go(feed_go),
        .a_stream_ready(a_stream_ready), .bt_stream_ready(bt_stream_ready),
        .a_fifo_valid(a_fifo_valid), .a_fifo_rdata(a_fifo_rdata),
        .bt_fifo_valid(bt_fifo_valid), .bt_fifo_rdata(bt_fifo_rdata),
        .pair_fire(pair_fire),
        .a_fifo_pop(a_fifo_pop_w), .bt_fifo_pop(bt_fifo_pop_w),
        .a_stream_valid(a_stream_valid_w), .a_stream_data(a_stream_data_w),
        .bt_stream_valid(bt_stream_valid_w), .bt_stream_data(bt_stream_data_w)
    );

    // ---- 阵列周期级控制：直接由 FSM 阶段信号组合译码 ----
    assign array_start_w     = ph_array_start;
    assign array_enable_w    = feed_go || drain_en;
    assign array_clear_acc_w = ph_array_start;
    assign array_flush_w     = drain_en;

    // ---- C tile 累加 -> 量化 -> 写回 ----
    wire [3:0]  acc_rd_idx;
    wire [`NPU_ACC_W-1:0] acc_rd_data;
    wire [31:0] quant_word;

    c_tile_acc_ctrl u_c_tile_acc_ctrl(
        .clk(clk), .rst(rst),
        .acc_tile_clear(acc_tile_clear), .load_mode(first_k_tile),
        .c_result_valid(c_result_valid), .c_result_index(c_result_index),
        .c_result(c_result),
        .acc_rd_idx(acc_rd_idx), .acc_rd_data(acc_rd_data)
    );

    result_quantizer u_result_quantizer(
        .acc_data(acc_rd_data), .qshift(lp_qs), .c_word(quant_word)
    );

    c_tile_write_ctrl u_c_tile_write_ctrl(
        .clk(clk), .rst(rst),
        .write_go(write_go), .c_base(c_base), .n_dim(lp_n),
        .valid_tm(valid_tm), .valid_tn(valid_tn),
        .acc_rd_idx(acc_rd_idx), .quant_word(quant_word),
        .cwr_valid(cwr_valid_w), .cwr_addr(cwr_addr_w), .cwr_data(cwr_data_w),
        .cwr_ready(cwr_ready), .cwr_empty(cwr_empty), .write_done(write_done)
    );

    // ---- 完成控制 ----
    done_ctrl u_done_ctrl(
        .clk(clk), .rst(rst),
        .start_pulse(start_pulse), .lp_m(lp_m), .lp_n(lp_n),
        .c_wr_pulse(c_wr_pulse), .fsm_done(fsm_done), .err_abort(err_abort),
        .core_done(core_done_w)
    );

    always @(*) begin
        a_addr = a_addr_w;
        a_re = a_re_w;
        bt_addr = bt_addr_w;
        bt_re = bt_re_w;
        a_fifo_pop = a_fifo_pop_w;
        bt_fifo_pop = bt_fifo_pop_w;
        array_start = array_start_w;
        array_enable = array_enable_w;
        array_clear_acc = array_clear_acc_w;
        array_flush = array_flush_w;
        a_stream_valid = a_stream_valid_w;
        a_stream_data = a_stream_data_w;
        bt_stream_valid = bt_stream_valid_w;
        bt_stream_data = bt_stream_data_w;
        cwr_valid = cwr_valid_w;
        cwr_addr = cwr_addr_w;
        cwr_data = cwr_data_w;
        core_busy = core_busy_w;
        core_done = core_done_w;
        error_code = error_code_w;
        // ---- lane 使能(边界 tile 越界行/列在 unpacker 侧补零) ----
        a_lane_en  = { (valid_tm >= 3'd4), (valid_tm >= 3'd3),
                       (valid_tm >= 3'd2), (valid_tm >= 3'd1) };
        bt_lane_en = { (valid_tn >= 3'd4), (valid_tn >= 3'd3),
                       (valid_tn >= 3'd2), (valid_tn >= 3'd1) };
    end

endmodule
