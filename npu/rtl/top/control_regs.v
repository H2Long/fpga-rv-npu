`timescale 1ns / 1ps
// control_regs — 保存软件配置并产生 start / clear_done 命令脉冲
//
// 控制寄存器地址：
//   0x00 CTRL  bit0=1: 启动一次 NPU 任务；bit1=1: 清除 DONE 状态
//   0x04 M     矩阵行数
//   0x08 N     矩阵列数
//   0x0C K     内积长度
//   0x10 TM    M 方向 Tile 大小
//   0x14 TN    N 方向 Tile 大小
//   0x18 TK    K 方向 Tile 大小
//   0x1C QUANT 量化右移位数
// CTRL 是命令寄存器，不保存 bit0/bit1；例如写 0x02 只产生 clear_done_req，
// 不会启动运算，回读 CTRL 时 bit0/bit1 始终为 0。
`include "npu_defines.vh"

module control_regs(
    input        clk,
    input        rst,
    input        req_valid,
    input        req_we,
    input        sel_ctrl,
    input [2:0]  ctrl_reg_off,
    input [31:0] req_wdata,
    input [3:0]  req_byte_en,
    output reg  [`NPU_DIM_W-1:0]  cfg_m,
    output reg  [`NPU_DIM_W-1:0]  cfg_n,
    output reg  [`NPU_DIM_W-1:0]  cfg_k,
    output reg  [`NPU_TILE_W-1:0] cfg_tm,
    output reg  [`NPU_TILE_W-1:0] cfg_tn,
    output reg  [`NPU_TK_W-1:0]   cfg_tk,
    output reg  [`NPU_QS_W-1:0]   cfg_qshift,
    output reg        start_req,        // 单拍
    output reg        clear_done_req,   // 单拍
    output reg [31:0] control_rdata
);

    // req_valid 只在 mmio_if 发布一笔已锁存的请求时有效一个周期。
    // 因此 wr 是“实际执行写入”的条件，不是简单地表示 cpu_we=1。
    // 配置寄存器均位于一个 32 位字的低字节；只接受 byte_en[0] 有效的写入。
    // 这样字节写和整字写的行为一致，同时不会误修改高位保留字段。
    wire wr = req_valid && sel_ctrl && req_we;
    wire byte0_wr = wr && req_byte_en[0];

    // 这两个信号是命令脉冲：只有写 0x00 CTRL 且低字节有效时才产生。
    // 写入 CTRL=0x01 -> start_req=1；写入 CTRL=0x02 -> clear_done_req=1。
    // 若同时写 CTRL=0x03，两个命令都会产生；start_ctrl 仅在对应状态接受命令。
    always @(*) begin
        start_req      = byte0_wr && (ctrl_reg_off == 3'd0) && req_wdata[0];
        clear_done_req = byte0_wr && (ctrl_reg_off == 3'd0) && req_wdata[1];
    end

    always @(posedge clk) begin
        if (rst) begin
            cfg_m <= 6'd4;  cfg_n <= 6'd4;  cfg_k <= 6'd4;
            cfg_tm <= 3'd4; cfg_tn <= 3'd4; cfg_tk <= 5'd4; cfg_qshift <= 5'd0;
        end else if (byte0_wr) begin
            case (ctrl_reg_off)
                3'd1: cfg_m     <= req_wdata[`NPU_DIM_W-1:0];
                3'd2: cfg_n     <= req_wdata[`NPU_DIM_W-1:0];
                3'd3: cfg_k     <= req_wdata[`NPU_DIM_W-1:0];
                3'd4: cfg_tm    <= req_wdata[`NPU_TILE_W-1:0];
                3'd5: cfg_tn    <= req_wdata[`NPU_TILE_W-1:0];
                3'd6: cfg_tk    <= req_wdata[`NPU_TK_W-1:0];
                3'd7: cfg_qshift<= req_wdata[`NPU_QS_W-1:0];
                default: ;      // 0x00 CTRL 只有命令位,不保存
            endcase
        end
    end

    // 寄存器回读(字读)。CTRL 本身是命令寄存器，不保存 start/clear 状态；
    // 所以读 0x00 得到 0，而不是得到上一次写入的 0x01/0x02。
    always @(*) begin
        control_rdata =
            (ctrl_reg_off == 3'd0) ? {30'd0, 2'b00}            :
            (ctrl_reg_off == 3'd1) ? {26'd0, cfg_m}            :
            (ctrl_reg_off == 3'd2) ? {26'd0, cfg_n}            :
            (ctrl_reg_off == 3'd3) ? {26'd0, cfg_k}            :
            (ctrl_reg_off == 3'd4) ? {29'd0, cfg_tm}           :
            (ctrl_reg_off == 3'd5) ? {29'd0, cfg_tn}           :
            (ctrl_reg_off == 3'd6) ? {27'd0, cfg_tk}           :
                                     {27'd0, cfg_qshift}       ;
    end

endmodule
