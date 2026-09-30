`timescale 1ns / 1ps
// array_ctrl — 将 FSM 阶段命令转换为 MAC 可直接使用的周期级控制。
//
// 该模块是组合译码层，不保存状态。feed_last 当前仅为接口兼容/波形可见性
// 保留信号；阵列的排空由 drain_en 和 drain_controller 统一控制。
`include "npu_defines.vh"

module array_ctrl(
    input ph_array_start,   // ARRAY_START 阶段
    input feed_go,          // ARRAY_FEED 阶段
    input drain_en,         // ARRAY_DRAIN 阶段
    input feed_last,        // 保留输入，当前阵列由 drain_en 控制排空
    output reg array_start,
    output reg array_enable,
    output reg array_clear_acc,
    output reg array_flush
);

    always @(*) begin
        array_start     = ph_array_start;
        array_clear_acc = ph_array_start;
        array_enable    = feed_go || drain_en;   // 喂数与排空期间阵列持续推进
        array_flush     = drain_en;
    end

endmodule
