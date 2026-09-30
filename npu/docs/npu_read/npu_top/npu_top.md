# `mmio_if` 当前时序笔记

本文档记录当前 RTL 中 `mmio_if` 的端口和状态机时序。当前复位接口为高有效同步复位 `rst`。

## 端口

CPU 侧输入为 `cpu_valid`、`cpu_we`、`cpu_addr`、`cpu_wdata` 和 `cpu_byte_en`；完成响应为 `cpu_ready`，读数据为 `cpu_rdata`。

请求锁存后，模块向下游发布 `req_addr`、`req_wdata`、`req_byte_en`、`req_we` 和单拍 `req_valid`。地址选择信号为 `sel_ctrl`、`sel_status` 和 `sel_buffer`；控制、状态和 Buffer 读数据分别通过 `control_rdata`、`status_rdata` 和 `buffer_rdata` 返回。

## 状态机

`mmio_if` 使用四个状态：

- `S_IDLE`：检测 `cpu_valid`，锁存 CPU 请求并产生一个周期的 `req_valid`。
- `S_WAIT1`：写请求在这里完成；寄存器读在这里锁存组合读数据；Buffer 读转入下一状态。
- `S_WAIT2`：等待同步 RAM 的读数据，在本状态锁存 `buffer_rdata`。
- `S_RESP`：把 `rdata_q` 送到 `cpu_rdata`，并产生一个周期的 `cpu_ready`。

## 时序

CPU 应在时钟采样沿之前保持请求信号稳定。以一次写操作为例：

1. 第一个 `clk` 上升沿在 `S_IDLE` 锁存 `cpu_*` 到 `req_*`，并拉高 `req_valid`。
2. 第二个 `clk` 上升沿在 `S_WAIT1` 判断 `req_we`，转入 `S_RESP`。
3. 第三个 `clk` 上升沿在 `S_RESP` 拉高 `cpu_ready`，表示本次写完成。

寄存器读与写操作使用相同的三次上升沿路径；Buffer 读还要经过 `S_WAIT2`，因此多等待一个时钟周期。

CPU 在采样到 `cpu_ready` 的同一拍应撤销 `cpu_valid`，否则回到 `S_IDLE` 后可能将同一请求再次锁存。
