`timescale 1ns / 1ps
// config_checker — 启动前检查配置合法性
//
// 错误优先级与错误码：
//   1. M/N/K 为 0                         -> NPU_ERR_DIM_ZERO
//   2. TM/TN 为 0 或超过 4x4 阵列          -> NPU_ERR_TILE_GT_ARRAY
//   3. TK 为 0、TK>K 或超过 FIFO 深度       -> NPU_ERR_TK_INVALID
//   4. A/BT/C 所需存储量超过 Buffer 容量    -> NPU_ERR_BUF_OVERFLOW
// cfg_ok 只有在全部检查通过时为 1。
`include "npu_defines.vh"

module config_checker(
    input [`NPU_DIM_W-1:0]  lp_m, lp_n, lp_k,
    input [`NPU_TILE_W-1:0] lp_tm, lp_tn,
    input [`NPU_TK_W-1:0]   lp_tk,
    output reg        cfg_ok,
    output reg [`NPU_ERR_W-1:0]  err_code
);

    // A/BT Buffer 字数 = ceil(M/TM) * K。
    // TM/TN 为 0 时不能做除法，先保留 0，后面的错误分支再返回 TILE 错误。
    integer a_words, bt_words, c_words;

    // 这里使用整数计算容量，不参与数据通路，只在启动前给 FSM 提供 cfg_ok/error_code。
    // A/BT 每个 32 位字装四个 INT8，但地址容量按“打包后的字数”计算。
    // 第一段组合逻辑只计算容量，避免在错误检查表达式中重复做除法。
    always @(*) begin
        a_words  = 0;
        bt_words = 0;
        c_words  = lp_m * lp_n;
        if (lp_tm != 0)
            a_words = ((lp_m + lp_tm - 1) / lp_tm) * lp_k;
        if (lp_tn != 0)
            bt_words = ((lp_n + lp_tn - 1) / lp_tn) * lp_k;
    end

    reg        cfg_ok_r;
    reg [`NPU_ERR_W-1:0] err_code_r;

    // 第二段组合逻辑按固定优先级给出唯一错误码。
    always @(*) begin
        cfg_ok_r   = 1'b1;
        err_code_r = `NPU_ERR_NONE;
        if (lp_m == 0 || lp_n == 0 || lp_k == 0) begin
            cfg_ok_r = 1'b0; err_code_r = `NPU_ERR_DIM_ZERO;
        end else if (lp_tm == 0 || lp_tn == 0 || lp_tm > `NPU_P || lp_tn > `NPU_Q) begin
            cfg_ok_r = 1'b0; err_code_r = `NPU_ERR_TILE_GT_ARRAY;
        end else if (lp_tk == 0 || lp_tk > lp_k || lp_tk > (1 << `NPU_FIFO_AW)) begin
            cfg_ok_r = 1'b0; err_code_r = `NPU_ERR_TK_INVALID;
        end else if (a_words > (1 << `NPU_ABUF_AW) || bt_words > (1 << `NPU_BBUF_AW)
                    || c_words > (1 << `NPU_CBUF_AW)) begin
            cfg_ok_r = 1'b0; err_code_r = `NPU_ERR_BUF_OVERFLOW;
        end
    end

    always @(*) begin
        cfg_ok   = cfg_ok_r;
        err_code = err_code_r;
    end

endmodule
