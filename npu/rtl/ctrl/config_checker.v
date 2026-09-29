// config_checker — 启动前检查配置合法性
//  1: M/N/K 为 0          2: TM>P 或 TN>Q 或 TM/TN 为 0
//  3: 矩阵占用超过 Buffer 容量  4: TK 为 0 / TK>K / TK>16(FIFO 深度)
`include "npu_defines.vh"

module config_checker(
    input  wire [`NPU_DIM_W-1:0]  lp_m, lp_n, lp_k,
    input  wire [`NPU_TILE_W-1:0] lp_tm, lp_tn,
    input  wire [`NPU_TK_W-1:0]   lp_tk,
    output wire        cfg_ok,
    output wire [`NPU_ERR_W-1:0]  err_code
);

    // A/BT Buffer 字数 = ceil(M/TM) * K。
    // TM/TN 为 0 时不能做除法，先保留 0，后面的错误分支再返回 TILE 错误。
    integer a_words, bt_words, c_words;

    // 这里使用整数计算容量，不参与数据通路，只在启动前给 FSM 提供 cfg_ok/error_code。
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

    assign cfg_ok   = cfg_ok_r;
    assign err_code = err_code_r;

endmodule
