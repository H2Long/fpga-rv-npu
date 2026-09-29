// systolic_fsm — 控制一个 C tile 的完整生命周期:
// IDLE -> CHECK_CONFIG -> LOAD_TILE_PARAM -> CLEAR_C_TILE
//      -> PREFETCH_INPUT -> ARRAY_START -> ARRAY_FEED -> ARRAY_DRAIN
//      -> RECEIVE_RESULT -> NEXT_K_OR_WRITE -> WRITE_C_TILE
//      -> NEXT_OUTPUT_TILE -> DONE
`include "npu_defines.vh"

module systolic_fsm(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start_pulse,
    input  wire        cfg_ok,
    input  wire [`NPU_ERR_W-1:0] chk_err_code,
    input  wire        core_done,          // done_ctrl 已发出 core_done
    // 边界/调度状态(loop_counters_tile_status)
    input  wire        first_k_tile,
    input  wire        last_k_tile,
    input  wire        last_output_tile,
    input  wire [`NPU_TK_W-1:0] valid_tk,
    // 预取状态(npu_buffer FIFO 计数)
    input  wire [`NPU_FIFO_AW:0] a_fifo_count, bt_fifo_count,
    // 喂数节拍(pair_stream_ctrl)
    input  wire        pair_fire,
    // MAC 状态(mac_status)
    input  wire        array_done,
    // C 写回状态(c_tile_write_ctrl)
    input  wire        write_done,
    // 输出
    output reg         sched_init,
    output reg         next_k_req,
    output reg         next_out_req,
    output reg         acc_tile_clear,     // 清 C tile 累加器
    output reg         prefetch_go,
    output reg         ph_array_start,     // ARRAY_START 阶段脉冲
    output reg         feed_go,
    output reg         drain_en,
    output reg         write_go,
    output reg         feed_last,          // 最后一对 A/BT 正在送入
    output wire        fsm_done,
    output reg         err_abort,
    output reg  [`NPU_ERR_W-1:0] error_code,
    output wire        core_busy
);

    localparam S_IDLE            = 4'd0;
    localparam S_CHECK_CONFIG    = 4'd1;
    localparam S_LOAD_TILE_PARAM = 4'd2;
    localparam S_CLEAR_C_TILE    = 4'd3;
    localparam S_PREFETCH_INPUT  = 4'd4;
    localparam S_ARRAY_START     = 4'd5;
    localparam S_ARRAY_FEED      = 4'd6;
    localparam S_ARRAY_DRAIN     = 4'd7;
    localparam S_RECEIVE_RESULT  = 4'd8;
    localparam S_NEXT_K_OR_WRITE = 4'd9;
    localparam S_WRITE_C_TILE    = 4'd10;
    localparam S_NEXT_OUTPUT_TILE= 4'd11;
    localparam S_DONE            = 4'd12;

    reg [3:0]  state;
    reg [5:0]  feed_cnt;      // 已送入的 A/BT 数据对数

    assign core_busy = (state != S_IDLE);
    assign fsm_done  = (state == S_DONE);

    // 预取完成条件：两个 FIFO 都已经拥有当前 K tile 的全部输入字。
    // stream_ctrl 在 go 期间只发 valid_tk 个请求，因此 count 不会跨 Tile 无限增长。
    wire prefetch_done = (a_fifo_count >= {1'b0, valid_tk}) &&
                         (bt_fifo_count >= {1'b0, valid_tk});
    wire feed_beat_done = pair_fire && (feed_cnt + 6'd1 >= {1'b0, valid_tk});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            sched_init <= 1'b0; next_k_req <= 1'b0; next_out_req <= 1'b0;
            acc_tile_clear <= 1'b0; prefetch_go <= 1'b0;
            ph_array_start <= 1'b0; feed_go <= 1'b0; drain_en <= 1'b0;
            write_go <= 1'b0; feed_last <= 1'b0; err_abort <= 1'b0;
            error_code <= `NPU_ERR_NONE;
            feed_cnt <= 6'd0;
        end else begin
            // 默认单拍/电平信号
            sched_init <= 1'b0; next_k_req <= 1'b0; next_out_req <= 1'b0;
            acc_tile_clear <= 1'b0; ph_array_start <= 1'b0;
            err_abort <= 1'b0; feed_last <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start_pulse) begin
                        error_code <= `NPU_ERR_NONE;
                        state <= S_CHECK_CONFIG;
                    end
                end

                S_CHECK_CONFIG: begin
                    if (!cfg_ok) begin
                        error_code <= chk_err_code;
                        err_abort  <= 1'b1;
                        state      <= S_DONE;
                    end else begin
                        state <= S_LOAD_TILE_PARAM;
                    end
                end

                S_LOAD_TILE_PARAM: begin
                    sched_init <= 1'b1;
                    state <= S_CLEAR_C_TILE;
                end

                S_CLEAR_C_TILE: begin
                    acc_tile_clear <= 1'b1;
                    feed_cnt <= 6'd0;
                    state <= S_PREFETCH_INPUT;
                end

                // 预取阶段不推进 PE，只等待两个 FIFO 都装满当前 K tile。
                S_PREFETCH_INPUT: begin
                    prefetch_go <= 1'b1;
                    feed_cnt    <= 6'd0;   // 每个 K tile 重新计数(K 间不经过 CLEAR_C_TILE)
                    if (prefetch_done) begin
                        prefetch_go <= 1'b0;
                        state <= S_ARRAY_START;
                    end
                end

                // 单拍启动阵列并清空 PE 累加器；下一拍才开始送入有效数据。
                S_ARRAY_START: begin
                    ph_array_start <= 1'b1;    // 阵列启动 + PE 累加器清零
                    state <= S_ARRAY_FEED;
                end

                // A/BT 必须成对 fire。最后一对被接受后立即停止 feed，下一阶段只排空。
                S_ARRAY_FEED: begin
                    feed_go <= 1'b1;
                    if (pair_fire) begin
                        feed_cnt <= feed_cnt + 6'd1;
                        if (feed_beat_done) begin
                            feed_last <= 1'b1;
                            feed_go   <= 1'b0;
                            state     <= S_ARRAY_DRAIN;
                        end
                    end
                end

                // 阵列继续 enable，让最后的波前穿过 PE；array_done 表示结果流已收完。
                S_ARRAY_DRAIN: begin
                    drain_en <= 1'b1;           // 阵列继续推进 + 排空(P+Q-2 拍)
                    if (array_done) begin       // 16 个结果已串行流出
                        drain_en <= 1'b0;
                        state <= S_RECEIVE_RESULT;
                    end
                end

                S_RECEIVE_RESULT: begin
                    state <= S_NEXT_K_OR_WRITE; // 结果已被 c_tile_acc_ctrl 消费
                end

                S_NEXT_K_OR_WRITE: begin
                    if (!last_k_tile) begin
                        next_k_req <= 1'b1;     // tile_k++, 继续累加部分和
                        state <= S_PREFETCH_INPUT;
                    end else begin
                        state <= S_WRITE_C_TILE;
                    end
                end

                // write_done 只有在 C 写 FIFO 排空且所有有效 lane 已入队后才会成立。
                S_WRITE_C_TILE: begin
                    write_go <= 1'b1;
                    if (write_done) begin
                        write_go <= 1'b0;
                        state <= last_output_tile ? S_DONE : S_NEXT_OUTPUT_TILE;
                    end
                end

                S_NEXT_OUTPUT_TILE: begin
                    next_out_req <= 1'b1;       // tile_j/tile_i 前进
                    state <= S_CLEAR_C_TILE;
                end

                S_DONE: begin
                    if (core_done)              // 等待最后一笔 C 写真正落 RAM
                        state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
