// buffer_status — 汇总 Buffer 可访问状态
`include "npu_defines.vh"

module buffer_status(
    input  wire core_busy,
    output wire buffer_ready,
    output wire access_error      // CPU 在 core_busy 期间发起访问(保留,当前无)
);
    assign buffer_ready  = !core_busy;
    assign access_error  = 1'b0;
endmodule
