// npu_sync_fifo — 通用 FWFT(首字直通)同步 FIFO
// rdata 组合直出队头;push/pop 同拍允许;count 为 0..depth
`include "npu_defines.vh"

module npu_sync_fifo #(parameter AW = `NPU_FIFO_AW, DW = 32) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        push,
    input  wire [DW-1:0] wdata,
    input  wire        pop,
    output wire [DW-1:0] rdata,
    output wire        valid,      // !empty
    output wire        empty,
    output wire        full,
    output wire [AW:0] count
);

    reg [DW-1:0] mem [0:(1<<AW)-1];
    reg [AW-1:0]  rd_ptr, wr_ptr;
    reg [AW:0]    cnt;

    assign rdata = mem[rd_ptr];
    assign valid = (cnt != 0);
    assign empty = (cnt == 0);
    assign full  = (cnt == (1<<AW));
    assign count = cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr <= 0; wr_ptr <= 0; cnt <= 0;
        end else begin
            case ({push && !full, pop && !empty})
                2'b10: begin mem[wr_ptr] <= wdata; wr_ptr <= wr_ptr + 1'b1; cnt <= cnt + 1'b1; end
                2'b01: begin                        rd_ptr <= rd_ptr + 1'b1; cnt <= cnt - 1'b1; end
                2'b11: begin mem[wr_ptr] <= wdata; wr_ptr <= wr_ptr + 1'b1;
                             rd_ptr <= rd_ptr + 1'b1; end
                default: ;
            endcase
        end
    end

endmodule
