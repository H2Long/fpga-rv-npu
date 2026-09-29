// control_regs — 保存软件配置并产生 start / clear_done 命令脉冲
// 0x00 CTRL | 0x04 M | 0x08 N | 0x0C K | 0x10 TM | 0x14 TN | 0x18 TK | 0x1C QUANT(右移位数)
`include "npu_defines.vh"

module control_regs(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        req_valid,
    input  wire        req_we,
    input  wire        sel_ctrl,
    input  wire [2:0]  ctrl_reg_off,
    input  wire [31:0] req_wdata,
    input  wire [3:0]  req_byte_en,
    output reg  [`NPU_DIM_W-1:0]  cfg_m,
    output reg  [`NPU_DIM_W-1:0]  cfg_n,
    output reg  [`NPU_DIM_W-1:0]  cfg_k,
    output reg  [`NPU_TILE_W-1:0] cfg_tm,
    output reg  [`NPU_TILE_W-1:0] cfg_tn,
    output reg  [`NPU_TK_W-1:0]   cfg_tk,
    output reg  [`NPU_QS_W-1:0]   cfg_qshift,
    output wire        start_req,        // 单拍
    output wire        clear_done_req,   // 单拍
    output wire [31:0] control_rdata
);

    // 配置寄存器均位于一个 32 位字的低字节；只接受 byte_en[0] 有效的写入。
    // 这样字节写和整字写的行为一致，同时不会误修改高位保留字段。
    wire wr = req_valid && sel_ctrl && req_we;
    wire byte0_wr = wr && req_byte_en[0];

    assign start_req      = byte0_wr && (ctrl_reg_off == 3'd0) && req_wdata[0];
    assign clear_done_req = byte0_wr && (ctrl_reg_off == 3'd0) && req_wdata[1];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
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

    // 寄存器回读(字读)。CTRL 本身是命令寄存器，不保存 start/clear 状态。
    assign control_rdata =
        (ctrl_reg_off == 3'd0) ? {30'd0, 2'b00}            :
        (ctrl_reg_off == 3'd1) ? {26'd0, cfg_m}            :
        (ctrl_reg_off == 3'd2) ? {26'd0, cfg_n}            :
        (ctrl_reg_off == 3'd3) ? {26'd0, cfg_k}            :
        (ctrl_reg_off == 3'd4) ? {29'd0, cfg_tm}           :
        (ctrl_reg_off == 3'd5) ? {29'd0, cfg_tn}           :
        (ctrl_reg_off == 3'd6) ? {27'd0, cfg_tk}           :
                                 {27'd0, cfg_qshift}       ;

endmodule
