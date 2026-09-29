// result_quantizer — ACC_W 位累加结果 -> 32 位 C 字:
//   acc + (1<<(s-1)) >> s(四舍五入右移,s=0 直通) -> 饱和到有符号 32 位
`include "npu_defines.vh"

module result_quantizer(
    input  wire [`NPU_ACC_W-1:0] acc_data,    // 解释为有符号
    input  wire [`NPU_QS_W-1:0]  qshift,
    output reg  [31:0] c_word
);

    reg signed [63:0] t;

    always @(*) begin
        if (qshift == 5'd0) begin
            c_word = acc_data;                          // 直通(数值范围已保证不溢出)
        end else begin
            // 64 位中间量做舍入右移(acc_data 按有符号解释,显式符号扩展)
            t = $signed(acc_data);
            t = (t + (64'sd1 << (qshift - 1))) >>> qshift;
            if (t > 64'sd2147483647)        c_word = 32'h7FFF_FFFF;   // 饱和
            else if (t < -64'sd2147483648)  c_word = 32'h8000_0000;
            else                            c_word = t[31:0];
        end
    end

endmodule
