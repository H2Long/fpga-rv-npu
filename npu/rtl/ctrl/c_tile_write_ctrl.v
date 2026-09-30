`timescale 1ns / 1ps
// c_tile_write_ctrl — C Tile 结果快照与写回扫描
//
// snap_valid_in（排空完成那一拍）把 PE 的 16 个累加器整块锁存进影子寄存器，
// 之后逐拍扫描 16 个物理 lane：选出对应累加器 -> 量化 -> 入 C 写 FIFO。
// 因为结果已经搬到影子寄存器，阵列可以立刻开始下一个输出 Tile 的计算，
// 写回与下一块计算并行，因此本模块不再需要状态机参与（没有 write_go 状态）。
//
// 边界 Tile 中 r>=valid_tm 或 c>=valid_tn 的 lane 不入队，但 idx 仍然跳过，
// 所以扫描总是 16 拍（FIFO 有空间时），不会因为边界而改变时序长度。
// idle_out 表示"没有扫描在跑且 C 写 FIFO 已排空"：状态机用它保证下一次快照
// 不会覆盖还没写回的结果，tile_controller 用它判断整个任务是否真正写完。
//
// 快照只会被消费一次：snap_valid_in 是电平（会多保持一拍），
// 因此捕获条件里带 !active_q，扫描进行中重复到达的 snap_valid_in 被忽略。
//
// 重要：写回地址和边界尺寸必须和累加器一起锁存。状态机在排空完成的同一拍就
// 发出 next_out_req 去启动下一个输出 Tile，所以扫描期间 tile_controller 给出的
// c_base/valid_tm/valid_tn 已经是"下一块"的值，直接用会把整块结果写错地址。
`include "npu_defines.vh"

module c_tile_write_ctrl(
    input        clk,
    input        rst,
    // 来自 npu_mac
    input [`NPU_PE_NUM*`NPU_ACC_W-1:0] acc_flat_in,
    input        snap_valid_in,
    // 来自 tile_controller
    input [`NPU_CBASE_W-1:0] c_base_in,
    input [`NPU_DIM_W-1:0]   n_dim_in,
    input [`NPU_TILE_W-1:0]  valid_tm_in,
    input [`NPU_TILE_W-1:0]  valid_tn_in,
    input [`NPU_QS_W-1:0]    qshift_in,
    // 到 c_write_fifo
    input        cwr_ready_in,          // FIFO 未满
    input        cwr_empty_in,          // FIFO 已排空
    output reg   cwr_valid_out,
    output reg [`NPU_CBUF_AW-1:0] cwr_addr_out,
    output reg [31:0] cwr_data_out,
    // 状态
    output reg   idle_out
);

    reg [`NPU_PE_NUM*`NPU_ACC_W-1:0] snap_q;   // 结果快照
    reg [`NPU_CBASE_W-1:0] c_base_q;           // 快照对应的 C 基地址
    reg [`NPU_DIM_W-1:0]   n_dim_q;            // 快照对应的 N
    reg [`NPU_TILE_W-1:0]  valid_tm_q;         // 快照对应的有效行数
    reg [`NPU_TILE_W-1:0]  valid_tn_q;         // 快照对应的有效列数
    reg [4:0]  idx_q;                          // 0..15 扫描，16 表示扫描完成
    reg        active_q;

    reg [`NPU_ACC_W-1:0] acc_sel;
    wire [31:0] quant_word;

    wire [1:0] r = idx_q[3:2];
    wire [1:0] c = idx_q[1:0];

    wire lane_ok = (idx_q < 5'd16) &&
                   ({1'b0, r} < valid_tm_q) && ({1'b0, c} < valid_tn_q);

    // 有效 lane 且 FIFO 有空间时入队并前进；无效 lane 直接跳过。
    wire advance = active_q && (idx_q < 5'd16) && (lane_ok ? cwr_ready_in : 1'b1);

    wire [`NPU_CBASE_W+1:0] c_addr = c_base_q + r * n_dim_q + c;

    result_quantizer u_result_quantizer(
        .acc_data(acc_sel), .qshift(qshift_in), .c_word(quant_word)
    );

    always @(posedge clk) begin
        if (rst) begin
            snap_q     <= {`NPU_PE_NUM*`NPU_ACC_W{1'b0}};
            c_base_q   <= {`NPU_CBASE_W{1'b0}};
            n_dim_q    <= {`NPU_DIM_W{1'b0}};
            valid_tm_q <= {`NPU_TILE_W{1'b0}};
            valid_tn_q <= {`NPU_TILE_W{1'b0}};
            idx_q      <= 5'd0;
            active_q   <= 1'b0;
        end else if (snap_valid_in && !active_q) begin
            snap_q     <= acc_flat_in;
            c_base_q   <= c_base_in;
            n_dim_q    <= n_dim_in;
            valid_tm_q <= valid_tm_in;
            valid_tn_q <= valid_tn_in;
            idx_q      <= 5'd0;
            active_q   <= 1'b1;
        end else if (advance) begin
            idx_q <= idx_q + 5'd1;
            if (idx_q == 5'd15)
                active_q <= 1'b0;      // 本拍送走最后一个 lane
        end
    end

    always @(*) begin
        acc_sel       = snap_q[idx_q[3:0]*`NPU_ACC_W +: `NPU_ACC_W];
        idle_out      = !active_q && cwr_empty_in;
        // cwr_valid_out 与 cwr_ready_in 相与，表示本拍一定能完成一次 FIFO 入队。
        cwr_valid_out = active_q && lane_ok && cwr_ready_in;
        cwr_addr_out  = c_addr[`NPU_CBUF_AW-1:0];
        cwr_data_out  = quant_word;
    end

endmodule
