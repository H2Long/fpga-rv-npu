// mmio_if — CPU MMIO 总线入口
// 锁存一笔 CPU 读写请求;寄存器读/写 1 个等待周期,Buffer 同步读 2 个等待周期;
// 完成时输出单拍 cpu_ready。
`include "npu_defines.vh"

module mmio_if(
    input  wire        clk,
    input  wire        rst_n,
    // CPU 侧
    input  wire        cpu_valid,
    input  wire        cpu_we,
    input  wire [31:0] cpu_addr,
    input  wire [31:0] cpu_wdata,
    input  wire [3:0]  cpu_byte_en,
    output reg         cpu_ready,
    output reg  [31:0] cpu_rdata,
    // 内部锁存请求(送 addr_decoder / 目标模块)
    output reg  [31:0] req_addr,
    output reg  [31:0] req_wdata,
    output reg  [3:0]  req_byte_en,
    output reg         req_we,
    output reg         req_valid,     // 锁存后单拍有效
    // 对 req_addr 的组合译码结果(addr_decoder 提供)
    input  wire        sel_ctrl,
    input  wire        sel_status,
    input  wire        sel_buffer,
    // 三类读数据源
    input  wire [31:0] control_rdata,
    input  wire [31:0] status_rdata,
    input  wire [31:0] buffer_rdata
);

    localparam S_IDLE  = 2'd0;
    localparam S_WAIT1 = 2'd1;   // 目标执行写 / RAM 给出读数据
    localparam S_WAIT2 = 2'd2;   // Buffer 同步读数据寄存
    localparam S_RESP  = 2'd3;   // 返回 cpu_rdata + cpu_ready

    reg [1:0]  state;
    reg [31:0] rdata_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
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
                    end else if (sel_buffer) begin
                        state <= S_WAIT2;                   // 同步 RAM 读多等一拍
                    end else begin
                        rdata_q <= sel_ctrl ? control_rdata : status_rdata;
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
