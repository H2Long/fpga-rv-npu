// npu_ctrl — NPU 调度中心。
//
// 本模块不保存矩阵数据，只负责把一次 GEMM 拆成 Tile，并按以下顺序推动硬件：
// 参数锁存 -> 配置检查 -> Tile 选择 -> A/BT 预取 -> 阵列喂数/排空
// -> C partial-sum 累加 -> 量化和写回 -> 统计完成。
// 通过 start_pulse 锁存后的参数在整个任务期间保持不变。
`include "npu_defines.vh"

module npu_ctrl(
    input  wire        clk,
    input  wire        rst_n,
    // 来自 npu_top:start_pulse + 锁存后的任务参数
    input  wire        start_pulse,
    input  wire [`NPU_DIM_W-1:0]  cfg_m, cfg_n, cfg_k,
    input  wire [`NPU_TILE_W-1:0] cfg_tm, cfg_tn,
    input  wire [`NPU_TK_W-1:0]   cfg_tk,
    input  wire [`NPU_QS_W-1:0]   cfg_qshift,
    // A/BT RAM 读请求(经 npu_buffer.npu_read_port_ctrl)
    output wire [`NPU_ABUF_AW-1:0] a_addr,
    output wire        a_re,
    output wire [`NPU_BBUF_AW-1:0] bt_addr,
    output wire        bt_re,
    // 预取 FIFO 接口(来自 npu_buffer)
    input  wire        a_fifo_valid,
    input  wire [31:0] a_fifo_rdata,
    input  wire [`NPU_FIFO_AW:0] a_fifo_count,
    output wire        a_fifo_pop,
    input  wire        bt_fifo_valid,
    input  wire [31:0] bt_fifo_rdata,
    input  wire [`NPU_FIFO_AW:0] bt_fifo_count,
    output wire        bt_fifo_pop,
    // 到 npu_mac
    output wire        array_start, array_enable, array_clear_acc,
    output wire        array_flush, array_last,
    output wire        a_stream_valid,
    output wire [31:0] a_stream_data,
    output wire        bt_stream_valid,
    output wire [31:0] bt_stream_data,
    output wire [3:0]  a_lane_en, bt_lane_en,
    input  wire        a_stream_ready,
    input  wire        bt_stream_ready,
    input  wire        array_done,
    input  wire        c_result_valid,
    input  wire [31:0] c_result,
    input  wire [3:0]  c_result_index,
    input  wire        c_result_last,
    // C 写回(到 npu_buffer.c_write_fifo)
    output wire        cwr_valid,
    output wire [`NPU_CBUF_AW-1:0] cwr_addr,
    output wire [31:0] cwr_data,
    input  wire        cwr_ready, cwr_empty, c_wr_pulse,
    // 状态(到 npu_top)
    output wire        core_busy,
    output wire        core_done,
    output wire [`NPU_ERR_W-1:0] error_code
);

    // ---- 锁存参数 ----
    wire [`NPU_DIM_W-1:0]  lp_m, lp_n, lp_k;
    wire [`NPU_TILE_W-1:0] lp_tm, lp_tn;
    wire [`NPU_TK_W-1:0]   lp_tk;
    wire [`NPU_QS_W-1:0]   lp_qs;

    tile_param_latch u_tile_param_latch(
        .clk(clk), .rst_n(rst_n), .start_pulse(start_pulse),
        .cfg_m(cfg_m), .cfg_n(cfg_n), .cfg_k(cfg_k),
        .cfg_tm(cfg_tm), .cfg_tn(cfg_tn), .cfg_tk(cfg_tk), .cfg_qshift(cfg_qshift),
        .lp_m(lp_m), .lp_n(lp_n), .lp_k(lp_k),
        .lp_tm(lp_tm), .lp_tn(lp_tn), .lp_tk(lp_tk), .lp_qs(lp_qs)
    );

    // ---- 配置检查 ----
    wire cfg_ok;
    wire [`NPU_ERR_W-1:0] chk_err_code;

    config_checker u_config_checker(
        .lp_m(lp_m), .lp_n(lp_n), .lp_k(lp_k),
        .lp_tm(lp_tm), .lp_tn(lp_tn), .lp_tk(lp_tk),
        .cfg_ok(cfg_ok), .err_code(chk_err_code)
    );

    // ---- tile 调度与状态 ----
    wire [`NPU_TIDX_W-1:0] tile_i, tile_j, tile_k;
    wire sched_init, next_k_req, next_out_req;

    tile_scheduler u_tile_scheduler(
        .clk(clk), .rst_n(rst_n),
        .sched_init(sched_init), .next_k_req(next_k_req), .next_out_req(next_out_req),
        .lp_m(lp_m), .lp_n(lp_n), .lp_k(lp_k),
        .lp_tm(lp_tm), .lp_tn(lp_tn), .lp_tk(lp_tk),
        .tile_i(tile_i), .tile_j(tile_j), .tile_k(tile_k)
    );

    wire first_k_tile, last_k_tile, last_output_tile;
    wire [`NPU_TILE_W-1:0] valid_tm, valid_tn;
    wire [`NPU_TK_W-1:0]   valid_tk;

    loop_counters_tile_status u_loop_counters(
        .tile_i(tile_i), .tile_j(tile_j), .tile_k(tile_k),
        .lp_m(lp_m), .lp_n(lp_n), .lp_k(lp_k),
        .lp_tm(lp_tm), .lp_tn(lp_tn), .lp_tk(lp_tk),
        .first_k_tile(first_k_tile), .last_k_tile(last_k_tile),
        .last_output_tile(last_output_tile),
        .valid_tm(valid_tm), .valid_tn(valid_tn), .valid_tk(valid_tk)
    );

    // ---- tile 基地址 ----
    wire [`NPU_ABUF_AW-1:0] a_base;
    wire [`NPU_BBUF_AW-1:0] bt_base;
    wire [`NPU_CBASE_W-1:0] c_base;

    block_addr_gen u_block_addr_gen(
        .tile_i(tile_i), .tile_j(tile_j), .tile_k(tile_k),
        .lp_n(lp_n), .lp_k(lp_k), .lp_tm(lp_tm), .lp_tn(lp_tn), .lp_tk(lp_tk),
        .a_base(a_base), .bt_base(bt_base), .c_base(c_base)
    );

    // ---- 主状态机 ----
    // acc_tile_clear 必须在每个输出 Tile 开始时产生，不能只依赖 first_k_tile，
    // 因为切换 tile_i/tile_j 时也需要清除上一块 C 的部分和。
    wire prefetch_go, ph_array_start, feed_go, drain_en, write_go, feed_last;
    wire fsm_done, err_abort;
    wire pair_fire;
    wire write_done;               // c_tile_write_ctrl 完成
    wire acc_tile_clear;

    systolic_fsm u_systolic_fsm(
        .clk(clk), .rst_n(rst_n),
        .start_pulse(start_pulse), .cfg_ok(cfg_ok), .chk_err_code(chk_err_code),
        .core_done(core_done),
        .first_k_tile(first_k_tile), .last_k_tile(last_k_tile),
        .last_output_tile(last_output_tile), .valid_tk(valid_tk),
        .a_fifo_count(a_fifo_count), .bt_fifo_count(bt_fifo_count),
        .pair_fire(pair_fire), .array_done(array_done), .write_done(write_done),
        .sched_init(sched_init), .next_k_req(next_k_req), .next_out_req(next_out_req),
        .acc_tile_clear(acc_tile_clear), .prefetch_go(prefetch_go),
        .ph_array_start(ph_array_start), .feed_go(feed_go), .drain_en(drain_en),
        .write_go(write_go), .feed_last(feed_last),
        .fsm_done(fsm_done), .err_abort(err_abort),
        .error_code(error_code), .core_busy(core_busy)
    );

    // ---- A/BT 读流控制 ----
    a_stream_ctrl u_a_stream_ctrl(
        .clk(clk), .rst_n(rst_n),
        .a_base(a_base), .valid_tk(valid_tk), .prefetch_go(prefetch_go),
        .a_addr(a_addr), .a_re(a_re)
    );

    bt_stream_ctrl u_bt_stream_ctrl(
        .clk(clk), .rst_n(rst_n),
        .bt_base(bt_base), .valid_tk(valid_tk), .prefetch_go(prefetch_go),
        .bt_addr(bt_addr), .bt_re(bt_re)
    );

    // ---- 成对送数 ----
    pair_stream_ctrl u_pair_stream_ctrl(
        .feed_go(feed_go),
        .a_stream_ready(a_stream_ready), .bt_stream_ready(bt_stream_ready),
        .a_fifo_valid(a_fifo_valid), .a_fifo_rdata(a_fifo_rdata),
        .bt_fifo_valid(bt_fifo_valid), .bt_fifo_rdata(bt_fifo_rdata),
        .pair_fire(pair_fire),
        .a_fifo_pop(a_fifo_pop), .bt_fifo_pop(bt_fifo_pop),
        .a_stream_valid(a_stream_valid), .a_stream_data(a_stream_data),
        .bt_stream_valid(bt_stream_valid), .bt_stream_data(bt_stream_data)
    );

    // ---- 阵列周期级控制 ----
    array_ctrl u_array_ctrl(
        .ph_array_start(ph_array_start), .feed_go(feed_go), .drain_en(drain_en),
        .feed_last(feed_last),
        .array_start(array_start), .array_enable(array_enable),
        .array_clear_acc(array_clear_acc), .array_flush(array_flush),
        .array_last(array_last)
    );

    // ---- C tile 累加 -> 量化 -> 写回 ----
    wire [3:0]  acc_rd_idx;
    wire [`NPU_ACC_W-1:0] acc_rd_data;
    wire [31:0] quant_word;

    c_tile_acc_ctrl u_c_tile_acc_ctrl(
        .clk(clk), .rst_n(rst_n),
        .acc_tile_clear(acc_tile_clear), .load_mode(first_k_tile),
        .c_result_valid(c_result_valid), .c_result_index(c_result_index),
        .c_result(c_result),
        .acc_rd_idx(acc_rd_idx), .acc_rd_data(acc_rd_data)
    );

    result_quantizer u_result_quantizer(
        .acc_data(acc_rd_data), .qshift(lp_qs), .c_word(quant_word)
    );

    c_tile_write_ctrl u_c_tile_write_ctrl(
        .clk(clk), .rst_n(rst_n),
        .write_go(write_go), .c_base(c_base), .n_dim(lp_n),
        .valid_tm(valid_tm), .valid_tn(valid_tn),
        .acc_rd_idx(acc_rd_idx), .acc_rd_data(acc_rd_data), .quant_word(quant_word),
        .cwr_valid(cwr_valid), .cwr_addr(cwr_addr), .cwr_data(cwr_data),
        .cwr_ready(cwr_ready), .cwr_empty(cwr_empty), .write_done(write_done)
    );

    // ---- 完成控制 ----
    done_ctrl u_done_ctrl(
        .clk(clk), .rst_n(rst_n),
        .start_pulse(start_pulse), .lp_m(lp_m), .lp_n(lp_n),
        .c_wr_pulse(c_wr_pulse), .fsm_done(fsm_done), .err_abort(err_abort),
        .core_done(core_done)
    );

    // ---- lane 使能(边界 tile 越界行/列在 unpacker 侧补零) ----
    assign a_lane_en  = { (valid_tm >= 3'd4), (valid_tm >= 3'd3),
                          (valid_tm >= 3'd2), (valid_tm >= 3'd1) };
    assign bt_lane_en = { (valid_tn >= 3'd4), (valid_tn >= 3'd3),
                          (valid_tn >= 3'd2), (valid_tn >= 3'd1) };

endmodule
