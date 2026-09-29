// array_ctrl — 将 FSM 阶段命令转换为 MAC 可直接使用的周期级控制:
//   array_start / array_enable / array_clear_acc / array_flush / array_last
`include "npu_defines.vh"

module array_ctrl(
    input  wire ph_array_start,   // ARRAY_START 阶段
    input  wire feed_go,          // ARRAY_FEED 阶段
    input  wire drain_en,         // ARRAY_DRAIN 阶段
    input  wire feed_last,        // 最后一对输入
    output wire array_start,
    output wire array_enable,
    output wire array_clear_acc,
    output wire array_flush,
    output wire array_last
);

    assign array_start    = ph_array_start;
    assign array_clear_acc= ph_array_start;
    assign array_enable   = feed_go || drain_en;   // 喂数与排空期间阵列持续推进
    assign array_flush    = drain_en;
    assign array_last     = feed_last;

endmodule
