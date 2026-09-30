`timescale 1ns / 1ps
// systolic_fsm — 一次任务的主时序状态机
//
// 状态与转移（每个输出 Tile 走一遍 K 循环，只在 Tile 结束时排空一次）：
//   S_IDLE       start_pulse 到来 -> S_INIT
//   S_INIT       sched_init 复位 tile 计数器 -> S_CLEAR_ACC
//   S_CLEAR_ACC  清 PE 累加器并启动第一个 K Tile 的预取；
//                等 cwr_idle（上一块 C 已写完，快照不会被覆盖）-> S_PREFETCH
//   S_PREFETCH   等 A/BT FIFO 装满当前 K Tile -> S_FEED
//   S_FEED       成对喂 valid_tk 拍；离开时启动下一个 K Tile 的预取；
//                最后一个 K Tile -> S_DRAIN，否则 next_k_req -> S_PREFETCH
//   S_DRAIN      保持阵列推进 P+Q-2 拍让波前走完
//                -> 最后一个输出 Tile ? S_DONE : S_CLEAR_ACC
//   S_DONE       等 core_done（最后一块 C 已落入 RAM）-> S_IDLE
//
// 关键时序约定：
//   1. K Tile 之间不清累加器、不排空阵列，阵列在 S_PREFETCH 期间整体冻结。
//      整条 skew 管线一起冻结会保持所有 lane 的相对偏移，恢复后波前无缝续接，
//      所以跨 K Tile 的部分和留在 PE 里连续累加，TK 只是延迟/面积参数，
//      不再是每个 K Tile 都要付一次的排空开销。
//   2. 预取与喂数重叠：进入 S_FEED 时用 pf_next_start 启动下一个 K Tile 的突发，
//      S_PREFETCH 只负责等数据到齐，通常可以立刻通过。
//   3. 排空后结果由 c_tile_write_ctrl 锁存成快照并在后台写回，
//      状态机不等写回就进入下一个输出 Tile；core_done 才代表全部 C 已落 RAM。
`include "npu_defines.vh"

module systolic_fsm(
    input        clk,
    input        rst,
    input        start_pulse,
    input        core_done,          // 全部 C 元素已真正写入 C RAM
    input        last_k_tile,
    input        last_out_tile,
    input [`NPU_TK_W-1:0]  valid_tk,
    // 预取 FIFO 计数
    input [`NPU_FIFO_AW:0] a_fifo_count,
    input [`NPU_FIFO_AW:0] bt_fifo_count,
    // 喂数节拍(tile_controller 内部成对出队)
    input        pair_fire,
    // MAC 排空完成
    input        drain_done,
    // C 写回空闲(扫描未进行且写 FIFO 已排空)
    input        cwr_idle,
    // 输出
    output reg   sched_init,
    output reg   next_k_req,
    output reg   next_out_req,
    output reg   acc_clear,
    output reg   pf_start,         // 单拍：启动当前 K Tile 的预取
    output reg   pf_next_start,    // 单拍：启动下一个 K Tile 的预取
    output reg   feed_go,
    output reg   drain_en,
    output reg   array_enable,
    output reg   fsm_done,
    output reg   core_busy
);

    localparam [2:0]
        S_IDLE      = 3'd0,
        S_INIT      = 3'd1,
        S_CLEAR_ACC = 3'd2,
        S_PREFETCH  = 3'd3,
        S_FEED      = 3'd4,
        S_DRAIN     = 3'd5,
        S_DONE      = 3'd6;

    reg [2:0] state;
    reg [5:0] feed_cnt;      // 已送入的 A/BT 数据对数

    // 预取完成条件：两个 FIFO 都已经拥有当前 K Tile 的全部输入字。
    // burst 只发 valid_tk 个请求，且每个 K Tile 正好被消费 valid_tk 次，
    // 所以 count 不会跨 Tile 累积，>= 判断不会提前通过。
    wire prefetch_done  = (a_fifo_count  >= {1'b0, valid_tk}) &&
                          (bt_fifo_count >= {1'b0, valid_tk});
    wire feed_beat_done = pair_fire && (feed_cnt + 6'd1 >= {1'b0, valid_tk});

    always @(*) begin
        core_busy    = (state != S_IDLE);
        fsm_done     = (state == S_DONE);
        array_enable = feed_go || drain_en;
    end

    always @(posedge clk) begin
        if (rst) begin
            state         <= S_IDLE;
            sched_init    <= 1'b0;
            next_k_req    <= 1'b0;
            next_out_req  <= 1'b0;
            acc_clear     <= 1'b0;
            pf_start      <= 1'b0;
            pf_next_start <= 1'b0;
            feed_go       <= 1'b0;
            drain_en      <= 1'b0;
            feed_cnt      <= 6'd0;
        end else begin
            // 单拍脉冲默认清零；电平信号在各状态分支中显式拉高。
            // acc_clear 也在这里清零：它是"换输出 Tile 时的电平"，只在 S_CLEAR_ACC
            // 里重新拉高，否则会一直保持高把累加器每拍清零。
            sched_init    <= 1'b0;
            next_k_req    <= 1'b0;
            next_out_req  <= 1'b0;
            acc_clear     <= 1'b0;
            pf_start      <= 1'b0;
            pf_next_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start_pulse)
                        state <= S_INIT;
                end

                S_INIT: begin
                    sched_init <= 1'b1;
                    feed_cnt   <= 6'd0;
                    state      <= S_CLEAR_ACC;
                end

                // 每个输出 Tile 都从零开始累加；跨任务累加由 C 写回路径完成
                // （见 c_write_fifo 的读-改-写），因此这里无条件清零。
                S_CLEAR_ACC: begin
                    acc_clear <= 1'b1;
                    if (cwr_idle) begin
                        pf_start <= 1'b1;      // 启动当前 K Tile 的预取
                        state    <= S_PREFETCH;
                    end
                end

                // 预取已经与喂数重叠，这里通常只等最后几个字到齐。
                // feed_cnt 必须在这里清零：每个 K Tile 都要重新数 valid_tk 拍。
                S_PREFETCH: begin
                    feed_cnt <= 6'd0;
                    if (prefetch_done) begin
                        pf_next_start <= !last_k_tile;
                        state         <= S_FEED;
                    end
                end

                S_FEED: begin
                    feed_go <= 1'b1;
                    if (pair_fire) begin
                        feed_cnt <= feed_cnt + 6'd1;
                        if (feed_beat_done) begin
                            feed_go <= 1'b0;
                            if (last_k_tile) begin
                                state <= S_DRAIN;
                            end else begin
                                next_k_req <= 1'b1;
                                state      <= S_PREFETCH;
                            end
                        end
                    end
                end

                // 只有在所有 K Tile 都喂完后才排空一次，结果才完整。
                S_DRAIN: begin
                    drain_en <= 1'b1;
                    if (drain_done) begin
                        drain_en <= 1'b0;
                        if (last_out_tile) begin
                            state <= S_DONE;
                        end else begin
                            // 换输出 Tile：tile_j/tile_i 前进、tile_k 归零。
                            // 必须在进 S_CLEAR_ACC 之前发出，S_CLEAR_ACC 只有一个
                            // 周期窗口，下一个周期的 pf_start 要用新的 tile 基地址。
                            next_out_req <= 1'b1;
                            state        <= S_CLEAR_ACC;
                        end
                    end
                end

                S_DONE: begin
                    if (core_done)
                        state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
