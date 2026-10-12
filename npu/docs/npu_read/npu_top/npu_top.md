# `ahb_lite_slave` 与 `npu_top` 请求接口时序笔记

本文档记录当前 RTL 中 AHB-Lite 从机（`rtl/bus/ahb_lite_slave.v`）与 `npu_top`
之间原生请求接口的端口和时序。原 `mmio_if` 已在 v2.2 删除，NPU 对外只有
AHB-Lite 一条总线。当前复位接口：`HRESETn` 低有效，内部转成高有效同步复位 `rst`。

## 1. 对 AHB 一侧的端口

输入为 `HSEL`、`HADDR[31:0]`、`HTRANS[1:0]`、`HWRITE`、`HSIZE[2:0]`、
`HWDATA[31:0]`、`HREADY_in`；输出为 `HRDATA[31:0]`、`HREADYOUT`、`HRESP[1:0]`。
`HREADY_in` 在单从机系统里就是 `HREADYOUT` 回接；多从机时接互连的全局 `HREADY`。

## 2. 对 `npu_top` 一侧的原生请求

输出 `req_addr[31:0]`、`req_wdata[31:0]`、`req_byte_en[3:0]`、`req_we`、`req_valid`
（单拍脉冲）；输入 `sel_ctrl`、`sel_status`、`sel_a_buf`、`sel_bt_buf`、`sel_c_buf`
和 `control_rdata`、`status_rdata`、`buffer_rdata`。定义与已删除的 `mmio_if` 输出
完全一致，所以 `npu_top` 的译码和寄存器逻辑不需要改动。

`HADDR` 减 `ADDR_BASE`（默认 `0x4000_0000`）之后才是内部偏移地址。

## 3. 状态机

`ahb_lite_slave` 使用五个状态：

- `S_IDLE`：空闲，`HREADYOUT=1`，等有效地址阶段（`HSEL && HTRANS[1] && HREADY_in`）。
- `S_DATA`：数据阶段，发出 `req_valid`。寄存器访问和 Buffer 写当拍完成，`HREADYOUT=1`；
  Buffer 读因 `npu_ram` 是同步读，`HREADYOUT=0` 并转 `S_RDD`；错误条件转 `S_ERR1`。
- `S_RDD`：Buffer 读数据返回拍，`HREADYOUT=1`、`HRDATA=buffer_rdata`。
- `S_ERR1`：错误响应第 1 拍，`HRESP=ERROR` 且 `HREADYOUT=0`。
- `S_ERR2`：错误响应第 2 拍，`HRESP=ERROR` 且 `HREADYOUT=1`。

## 4. 三条容易写错的时序

1. **完成拍必须接受下一笔地址**。`cap_now = bus_phase && HREADYOUT`，在 `S_DATA`
   完成的同一拍锁存下一笔；漏掉这条，背靠背连续访问只会执行第 1、3、5… 笔。
2. **等待期间 master 保持地址与控制信号**，所以 `S_DATA`（Buffer 读）和 `S_ERR1`
   期间不要再次锁存，等 `HREADYOUT` 拉高那一拍再采。
3. **ERROR 必须两拍**，且第 1 拍 `HREADYOUT=0`、第 2 拍 `HREADYOUT=1`。

一次 0 等待访问（如写配置寄存器）的时序：

```text
拍 N   : 地址阶段（HSEL=1, HTRANS=NONSEQ, HADDR=目标）
拍 N+1 : S_DATA，req_valid=1，req_addr=addr_q，写操作在拍 N+1 的时钟沿落定；
         同时 HREADYOUT=1 完成本次传输，并（若总线上已有下一笔）锁存下一笔地址
```
