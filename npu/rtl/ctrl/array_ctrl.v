`timescale 1ns / 1ps
// array_ctrl — 将 FSM 阶段命令转换为 MAC 可直接使用的周期级控制。
//
// 该模块是组合译码层，不保存状态。feed_last 当前仅为接口兼容/波形可见性
// 保留信号；阵列的排空由 drain_en 和 drain_controller 统一控制。
`include "npu_defines.vh"

module array_ctrl(
    input  wire ph_array_start,   // ARRAY_START 阶段
    input  wire feed_go,          // ARRAY_FEED 阶段
    input  wire drain_en,         // ARRAY_DRAIN 阶段
    input  wire feed_last,        // 保留输入，当前阵列由 drain_en 控制排空
    output wire array_start,
    output wire array_enable,
    output wire array_clear_acc,
    output wire array_flush
);

    assign array_start    = ph_array_start;
    assign array_clear_acc = ph_array_start;
    assign array_enable   = feed_go || drain_en;   // 喂数与排空期间阵列持续推进
    assign array_flush    = drain_en;

endmodule
