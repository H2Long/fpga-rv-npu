`timescale 1ns / 1ps
// mmio_if — CPU MMIO 总线入口
//
// 该模块一次只处理一笔请求：
//   S_IDLE ：看到 cpu_valid 后锁存 cpu_addr/cpu_wdata/cpu_we，并发布 req_valid；
//   S_WAIT1：等待寄存器写入或寄存器读数据；Buffer 读转入 S_WAIT2；
//   S_WAIT2：等待同步 RAM 的读数据；
//   S_RESP ：把读数据送到 cpu_rdata，并用一个周期的 cpu_ready 应答。
// cpu_ready 表示“本笔访问完成”，不是持续的接收能力；CPU 看到它后应撤销
// cpu_valid，否则回到 S_IDLE 后可能再次接收同一笔请求。
`include "npu_defines.vh"

module mmio_if(
    input        clk,
    input        rst,
    // CPU 侧
    input        cpu_valid,
    input        cpu_we,
    input [31:0] cpu_addr,
    input [31:0] cpu_wdata,
    input [3:0]  cpu_byte_en,
    output reg         cpu_ready,
    output reg  [31:0] cpu_rdata,
    // 内部锁存请求(送 npu_top 译码和目标模块)
    output reg  [31:0] req_addr,
    output reg  [31:0] req_wdata,
    output reg  [3:0]  req_byte_en,
    output reg         req_we,
    output reg         req_valid,     // 锁存后单拍有效
    // 对 req_addr 的组合译码结果(npu_top 内联提供)
    input        sel_ctrl,
    input        sel_status,
    input        sel_a_buf,
    input        sel_bt_buf,
    input        sel_c_buf,
    // 三类读数据源
    input [31:0] control_rdata,
    input [31:0] status_rdata,
    input [31:0] buffer_rdata
);

    localparam S_IDLE  = 2'd0;
    localparam S_WAIT1 = 2'd1;   // 目标执行写 / 寄存器组合读数据准备好
    localparam S_WAIT2 = 2'd2;   // Buffer 同步读：等待 RAM 输出数据
    localparam S_RESP  = 2'd3;   // 返回 cpu_rdata，并脉冲 cpu_ready

    reg [1:0]  state;
    reg [31:0] rdata_q;

    // 请求生命周期：IDLE 接收请求，WAIT1 等待寄存器/写操作完成，
    // WAIT2 等待同步 Buffer RAM 返回，RESP 输出一个周期的 ready。
    always @(posedge clk) begin
        if (rst) begin
            state        <= S_IDLE;
            cpu_ready    <= 1'b0;
            cpu_rdata    <= 32'd0;
            req_addr     <= 32'd0;
            req_wdata    <= 32'd0;
            req_byte_en  <= 4'd0;
            req_we       <= 1'b0;
            req_valid    <= 1'b0;
            rdata_q      <= 32'd0;
        end else begin
            cpu_ready <= 1'b0;
            req_valid <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (cpu_valid) begin
                        // req_we 是当前请求的读写属性，会保持到下一笔请求；
                        // 真正执行写操作还必须同时满足下游的 req_valid=1。
                        req_addr    <= cpu_addr;
                        req_wdata   <= cpu_wdata;
                        req_byte_en <= cpu_byte_en;
                        req_we      <= cpu_we;
                        req_valid   <= 1'b1;
                        state       <= S_WAIT1;
                    end
                end
                S_WAIT1: begin
                    if (req_we) begin
                        state <= S_RESP;                    // 写操作到此完成
                    end else if (sel_a_buf || sel_bt_buf || sel_c_buf) begin
                        state <= S_WAIT2;                   // 同步 RAM 读多等一拍
                    end else begin
                        // 未列出的地址属于保留地址，读回 0（见地址与寄存器表）。
                        rdata_q <= sel_ctrl   ? control_rdata :
                                   sel_status ? status_rdata  : 32'd0;
                        state   <= S_RESP;
                    end
                end
                S_WAIT2: begin
                    rdata_q <= buffer_rdata;                // RAM 读数据本拍有效
                    state   <= S_RESP;
                end
                S_RESP: begin
                    cpu_rdata <= rdata_q;
                    cpu_ready <= 1'b1;
                    state     <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
