# NPU 架构详细介绍与接线说明

## 1. 文档目的

本文是 `npu_architecture.drawio` 的配套架构说明，介绍图中全部模块、模块间接线、主要信号和一次矩阵乘法任务的运行过程。

本架构执行有符号 INT8 矩阵乘法：

```text
C[M][N] = A[M][K] x B[K][N]
```

B 在装入片上存储前转置为 `BT[N][K]`。这样，A 的一行和 BT 的一行都可按 K 方向连续读取，适合向脉动阵列持续送数。

图中连线颜色含义如下：

| 颜色 | 含义 |
|---|---|
| 红色 | 配置、调度、启动、使能和其他控制信号 |
| 蓝色 | A 地址、数据或 A 通道控制 |
| 绿色 | BT 地址、数据或 BT 通道控制 |
| 橙色 | C 部分和、结果、量化与写回数据 |
| 灰色 | busy、done、ready、error 和读响应等状态反馈 |
| 黑色 | A/BT 混合数据或模块层次关系 |

方框底色表示模块归属：

| 底色 | 顶层模块 |
|---|---|
| 浅蓝 | `npu_top` |
| 浅黄 | `npu_ctrl` |
| 浅绿 | `npu_buffer` |
| 浅紫 | `npu_mac` |

## 2. 总体结构

当前架构包含 37 个功能方框：

```text
npu_system
|-- npu_top       7 个模块：CPU 接口、寄存器和访问仲裁
|-- npu_ctrl     14 个模块：参数、tile 调度、时序和 C 写回
|-- npu_buffer    8 个模块：A/BT/C 存储与 FIFO
`-- npu_mac       8 个模块：拆包、波前、PE 阵列和结果收集
```

四条主路径为：

```text
控制：CPU -> npu_top -> npu_ctrl -> npu_mac
A：   A Buffer -> A FIFO -> pair_stream_ctrl -> MAC
BT：  BT Buffer -> BT FIFO -> pair_stream_ctrl -> MAC
C：   MAC -> c_tile_acc_ctrl -> quantizer -> C write -> C Buffer
```

## 3. `npu_top` 模块

`npu_top` 面向 CPU，负责 MMIO 协议、地址译码、配置和状态寄存器、任务启动以及 CPU/NPU 对 Buffer 的访问仲裁。

### 3.1 `mmio_if`

CPU 总线入口。建议外部端口为：

```text
cpu_addr[31:0]
cpu_wdata[31:0]
cpu_rdata[31:0]
cpu_byte_en[3:0]
cpu_we
cpu_valid
cpu_ready
```

主要职责：

- 锁存一笔 CPU 读写请求；
- 将请求送入 `addr_decoder`；
- 等待控制寄存器、状态寄存器或 Buffer 返回数据；
- 对同步 RAM 读操作插入等待周期；
- 请求完成时产生 `cpu_ready`。

图中连接：

```text
mmio_if -> addr_decoder
status_regs -> mmio_if
control_regs -> mmio_if
buffer_access_ctrl -> mmio_if
```

后三条代表 CPU 读响应来源。

### 3.2 `addr_decoder`

根据 CPU 字节地址选择访问目标，不保存任何数据。推荐地址映射：

| 地址范围 | 访问目标 |
|---|---|
| `0x0000_0000` - `0x0000_001F` | 控制寄存器 |
| `0x0000_0020` - `0x0000_002F` | 状态寄存器 |
| `0x0000_1000` - `0x0000_10FF` | A Buffer |
| `0x0000_2000` - `0x0000_20FF` | BT Buffer |
| `0x0000_3000` - `0x0000_33FF` | C Buffer |

图中连接：

```text
mmio_if -> addr_decoder
addr_decoder -> control_regs
addr_decoder -> status_regs
addr_decoder -> buffer_access_ctrl
```

发送内容包括 `req_addr/req_wdata/req_we/req_valid/byte_en`、目标片选和局部地址。

### 3.3 `control_regs`

保存软件配置并产生命令脉冲：

| 寄存器 | 内容 |
|---|---|
| `CTRL` | `start`、`clear_done` |
| `M_CFG/N_CFG/K_CFG` | 矩阵尺寸 |
| `TM_CFG/TN_CFG/TK_CFG` | tile 尺寸 |

图中连接：

```text
addr_decoder -> control_regs
control_regs -> start_ctrl
control_regs -> mmio_if
```

`control_regs -> start_ctrl` 传递配置和 `start_req/clear_done_req`；返回 MMIO 的线用于寄存器回读。

### 3.4 `status_regs`

向 CPU 提供运行状态。建议字段：

```text
bit 0 BUSY
bit 1 DONE
bit 2 ERROR
bit 3 BUFFER_READY
```

图中输入来源：

```text
addr_decoder -> status_regs
start_ctrl -> status_regs
done_ctrl -> status_regs
buffer_status -> status_regs
config_checker -> status_regs
mac_status -> status_regs
```

图中输出：

```text
status_regs -> mmio_if
```

### 3.5 `start_ctrl`

管理一整次任务，而不是单个 tile。状态可定义为：

```text
IDLE -> RUNNING -> DONE -> IDLE
```

主要行为：

- 在空闲状态接受 `start_req`；
- 锁存 M/N/K 和 TM/TN/TK；
- 产生单周期 `start_pulse`；
- 运行期间保持 BUSY；
- 收到 `core_done` 后保持 DONE；
- 收到 `clear_done_req` 后返回 IDLE。

图中连接：

```text
control_regs -> start_ctrl
start_ctrl -> tile_param_latch
start_ctrl -> status_regs
systolic_fsm -> start_ctrl
done_ctrl -> start_ctrl
```

`systolic_fsm -> start_ctrl` 表示 `core_busy`，`done_ctrl -> start_ctrl` 表示任务完成。

### 3.6 `buffer_access_ctrl`

汇合 CPU 和 NPU 的 Buffer 访问请求，并决定当前端口所有权：

```text
core_busy = 0：CPU 可以访问 A/BT/C
core_busy = 1：NPU 读取 A/BT、写入 C
```

图中连接：

```text
addr_decoder -> buffer_access_ctrl
a_stream_ctrl -> buffer_access_ctrl
bt_stream_ctrl -> buffer_access_ctrl
systolic_fsm -> buffer_access_ctrl
buffer_access_ctrl -> cpu_port_ctrl
buffer_access_ctrl -> npu_read_port_ctrl
buffer_access_ctrl -> buffer_status
buffer_access_ctrl -> mmio_if
```

### 3.7 `cpu_port_ctrl`

将 CPU 的局部地址、写数据、byte enable 和读写使能转换为三块 RAM 的端口操作。

```text
buffer_access_ctrl -> cpu_port_ctrl
cpu_port_ctrl -> a_buffer
cpu_port_ctrl -> bt_buffer
cpu_port_ctrl -> c_buffer
```

图中采用一条方向线概括每块 RAM 的 CPU 读写端口；实际 RTL 还包含 RAM 到 CPU 的读数据返回信号。

## 4. `npu_ctrl` 模块

`npu_ctrl` 决定计算什么、访问哪里以及何时推进，是整个 NPU 的调度中心。

### 4.1 `tile_param_latch`

在 `start_pulse` 到来时锁存 M/N/K/TM/TN/TK，确保运行期间软件寄存器变化不会影响当前任务。

```text
start_ctrl -> tile_param_latch
tile_param_latch -> config_checker
tile_param_latch -> tile_scheduler
tile_param_latch -> block_addr_gen
```

### 4.2 `config_checker`

启动前检查：

- 所有矩阵和 tile 尺寸非零；
- `TM<=P`、`TN<=Q`；
- A/BT/C 占用不超过 Buffer 容量；
- 地址乘加不会溢出；
- 边界 tile 可以合法补零。

图中连接：

```text
tile_param_latch -> config_checker
config_checker -> tile_scheduler
config_checker -> systolic_fsm
config_checker -> status_regs
```

最后一条传递配置错误和错误码。

### 4.3 `tile_scheduler`

实现三层分块循环：

```text
for tile_i
  for tile_j
    for tile_k
```

其中 `(tile_i,tile_j)` 选择一个输出 C tile，`tile_k` 遍历 K 方向的所有 partial tile。

```text
tile_param_latch/config_checker -> tile_scheduler
tile_scheduler -> loop_counters_tile_status
```

### 4.4 `loop_counters_tile_status`

保存 `tile_i/tile_j/tile_k`，并生成：

```text
first_k_tile
last_k_tile
last_output_tile
valid_tm/valid_tn/valid_tk
```

边界有效尺寸为：

```text
valid_tm = min(TM, M - tile_i*TM)
valid_tn = min(TN, N - tile_j*TN)
valid_tk = min(TK, K - tile_k*TK)
```

图中连接：

```text
tile_scheduler -> loop_counters_tile_status
loop_counters_tile_status -> block_addr_gen
loop_counters_tile_status -> systolic_fsm
```

### 4.5 `block_addr_gen`

根据 tile 下标计算 A、BT 和 C 的元素地址：

```text
A_base  = tile_i*TM*K + tile_k*TK
BT_base = tile_j*TN*K + tile_k*TK
C_base  = tile_i*TM*N + tile_j*TN
```

图中连接：

```text
tile_param_latch -> block_addr_gen
loop_counters_tile_status -> block_addr_gen
block_addr_gen -> a_stream_ctrl
block_addr_gen -> bt_stream_ctrl
block_addr_gen -> c_tile_write_ctrl
```

蓝、绿、橙三条输出分别代表 A、BT、C 地址。

### 4.6 `systolic_fsm`

控制一个 tile 的完整生命周期：

```text
IDLE -> CHECK_CONFIG -> LOAD_TILE_PARAM -> CLEAR_C_TILE
 -> PREFETCH_INPUT -> ARRAY_START -> ARRAY_FEED -> ARRAY_DRAIN
 -> RECEIVE_RESULT -> NEXT_K_OR_WRITE -> WRITE_C_TILE
 -> NEXT_OUTPUT_TILE -> DONE
```

图中控制输出：

```text
systolic_fsm -> a_stream_ctrl
systolic_fsm -> bt_stream_ctrl
systolic_fsm -> pair_stream_ctrl
systolic_fsm -> array_ctrl
systolic_fsm -> c_tile_acc_ctrl
systolic_fsm -> c_tile_write_ctrl
systolic_fsm -> done_ctrl
```

图中状态输出和输入：

```text
systolic_fsm -> start_ctrl
systolic_fsm -> buffer_access_ctrl
mac_status -> systolic_fsm
```

### 4.7 `a_stream_ctrl`

根据 A tile 地址按节拍发起 RAM 读请求，跟踪请求数和返回数，并处理边界补零。

```text
block_addr_gen -> a_stream_ctrl
systolic_fsm -> a_stream_ctrl
a_stream_ctrl -> buffer_access_ctrl
```

A 元素地址转换为 32 位字地址时使用 `elem_addr >> 2`，低两位选择字内 INT8。

### 4.8 `bt_stream_ctrl`

功能与 A 控制器相同，但访问转置矩阵 BT：

```text
block_addr_gen -> bt_stream_ctrl
systolic_fsm -> bt_stream_ctrl
bt_stream_ctrl -> buffer_access_ctrl
```

### 4.9 `pair_stream_ctrl`

保证 A 和 BT 在同一拍成对进入 MAC，避免一侧独立前进造成 K 序号错配。

```text
pair_valid  = a_fifo_valid && bt_fifo_valid
pair_ready  = a_stream_ready && bt_stream_ready
a_fifo_pop  = pair_valid && pair_ready
bt_fifo_pop = pair_valid && pair_ready
```

图中连接：

```text
systolic_fsm -> pair_stream_ctrl
a_prefetch_fifo -> pair_stream_ctrl
bt_prefetch_fifo -> pair_stream_ctrl
pair_stream_ctrl -> a_input_unpacker
pair_stream_ctrl -> bt_input_unpacker
```

### 4.10 `array_ctrl`

将 FSM 的阶段命令转换成 MAC 可直接使用的周期级控制：

```text
array_start
array_enable
array_clear_acc
array_flush
array_last
```

图中连接：

```text
systolic_fsm -> array_ctrl
array_ctrl -> a_bt_skew_pipeline
array_ctrl -> pe_array
array_ctrl -> drain_controller
```

分别控制波前管线推进、PE 启动/清零/保持和最后输入后的阵列排空。

### 4.11 `c_tile_acc_ctrl`

保存最多 P*Q 个 `ACC_W` 位累加值。对第一个 K tile 清零，后续 K tile 按 `c_result_index` 累加，最后一个 K tile 完成后交给量化器。

```text
systolic_fsm -> c_tile_acc_ctrl
output_reorder -> c_tile_acc_ctrl
c_tile_acc_ctrl -> result_quantizer
```

### 4.12 `result_quantizer`

把 `ACC_W` 位累加结果转换成 C Buffer 的 32 位格式：

```text
ACC_W result -> rounding/shift -> saturation -> 32-bit C word
```

如果不需要定点缩放，可采用有符号 32 位直通或饱和。

```text
c_tile_acc_ctrl -> result_quantizer
result_quantizer -> c_tile_write_ctrl
```

### 4.13 `c_tile_write_ctrl`

根据 C tile 基地址和 tile 内 `(r,c)` 生成 C 字地址，向写 FIFO 输出地址、数据和写有效信号。

```text
block_addr_gen -> c_tile_write_ctrl
systolic_fsm -> c_tile_write_ctrl
result_quantizer -> c_tile_write_ctrl
c_tile_write_ctrl -> c_write_fifo
```

### 4.14 `done_ctrl`

只有最后一个输出 tile 的最后一个 C 写操作实际完成后，才产生 `core_done`。不能在结果仅进入写 FIFO 时提前完成。

```text
systolic_fsm -> done_ctrl
c_write_fifo -> done_ctrl
done_ctrl -> start_ctrl
done_ctrl -> status_regs
```

## 5. `npu_buffer` 模块

### 5.1 `npu_read_port_ctrl`

接收 NPU 的 A/BT 读地址和读使能，驱动 RAM，并将同步 RAM 返回与请求顺序对应起来。

```text
buffer_access_ctrl -> npu_read_port_ctrl
npu_read_port_ctrl -> a_buffer
npu_read_port_ctrl -> bt_buffer
```

### 5.2 `a_buffer`

默认容量为 `64 x 32 bit`，即 256 个 INT8 元素。一个字的布局为：

```text
[7:0] element 0
[15:8] element 1
[23:16] element 2
[31:24] element 3
```

```text
cpu_port_ctrl -> a_buffer
npu_read_port_ctrl -> a_buffer
a_buffer -> a_prefetch_fifo
```

### 5.3 `bt_buffer`

默认容量同样为 `64 x 32 bit`，存储 N x K 行主序的转置矩阵。

```text
cpu_port_ctrl -> bt_buffer
npu_read_port_ctrl -> bt_buffer
bt_buffer -> bt_prefetch_fifo
```

### 5.4 `c_buffer`

默认容量为 `256 x 32 bit`，建议一个 32 位字存储一个 C 元素。

```text
cpu_port_ctrl -> c_buffer
c_write_fifo -> c_buffer
```

CPU 在任务完成后通过 CPU 端口读取结果。

### 5.5 `a_prefetch_fifo`

缓存 A RAM 返回数据，吸收同步 RAM 延迟和 MAC 的短时停顿。

```text
a_buffer -> a_prefetch_fifo
a_prefetch_fifo -> pair_stream_ctrl
```

### 5.6 `bt_prefetch_fifo`

缓存 BT RAM 返回数据：

```text
bt_buffer -> bt_prefetch_fifo
bt_prefetch_fifo -> pair_stream_ctrl
```

### 5.7 `c_write_fifo`

将 C tile 写回控制与 RAM 写时序解耦：

```text
c_tile_write_ctrl -> c_write_fifo
c_write_fifo -> c_buffer
c_write_fifo -> done_ctrl
```

到 `done_ctrl` 的灰线表示最后一次写入真正完成，而不是 FIFO 仅仅接收了数据。

### 5.8 `buffer_status`

汇总 Buffer 可访问状态、输入是否准备完成和访问错误：

```text
buffer_access_ctrl -> buffer_status
buffer_status -> status_regs
```

## 6. `npu_mac` 模块

### 6.1 `a_input_unpacker`

将一拍 A 数据拆成 P 个有符号 INT8 lane。4x4 阵列时：

```text
a0 = data[7:0]
a1 = data[15:8]
a2 = data[23:16]
a3 = data[31:24]
```

```text
pair_stream_ctrl -> a_input_unpacker
a_input_unpacker -> a_bt_skew_pipeline
```

### 6.2 `bt_input_unpacker`

将 BT 字拆成 Q 个有符号 INT8 lane：

```text
pair_stream_ctrl -> bt_input_unpacker
bt_input_unpacker -> a_bt_skew_pipeline
```

### 6.3 `a_bt_skew_pipeline`

为不同 A 行和 BT 列引入递增延迟，形成脉动波前：

```text
A row r delay = r
BT col c delay = c
```

数据和 valid 必须同步延迟。阵列暂停时，整个 skew 管线必须保持。

```text
a_input_unpacker/bt_input_unpacker -> a_bt_skew_pipeline
array_ctrl -> a_bt_skew_pipeline
a_bt_skew_pipeline -> pe_array
```

### 6.4 `pe_array`

由 P x Q 个 PE 组成。A 从左向右传播，BT 从上向下传播，每个 PE 对属于自己的 C 元素执行有符号乘加：

```text
acc[i][j] += signed(A[i][k]) * signed(BT[j][k])
```

```text
a_bt_skew_pipeline -> pe_array
array_ctrl -> pe_array
pe_array -> tile_result_collector
```

### 6.5 `drain_controller`

最后一对输入进入后，等待其传播到阵列最远端。无额外流水线时，基础排空距离至少是 `P+Q-2` 拍。

```text
array_ctrl -> drain_controller
drain_controller -> tile_result_collector
drain_controller -> mac_status
```

### 6.6 `tile_result_collector`

排空完成后锁存 P*Q 个 PE 累加结果，并将并行结果转换为串行流。

```text
pe_array -> tile_result_collector
drain_controller -> tile_result_collector
tile_result_collector -> output_reorder
```

典型输出字段：

```text
c_result[ACC_W-1:0]
c_result_index
c_result_valid
c_result_last
```

### 6.7 `output_reorder`

将 PE 物理坐标转换为 C tile 行主序：

```text
c_result_index = row*Q + column
```

```text
tile_result_collector -> output_reorder
output_reorder -> c_tile_acc_ctrl
```

### 6.8 `mac_status`

汇总 MAC 的运行和错误状态：

```text
array_ready
array_busy
array_done
error_flag
```

图中连接：

```text
drain_controller -> mac_status
mac_status -> systolic_fsm
mac_status -> status_regs
```

## 7. 接线总表

### 7.1 控制与状态

```text
mmio_if -> addr_decoder
addr_decoder -> control_regs/status_regs/buffer_access_ctrl
control_regs -> start_ctrl
start_ctrl -> tile_param_latch/status_regs
tile_param_latch -> config_checker/tile_scheduler/block_addr_gen
config_checker -> tile_scheduler/systolic_fsm/status_regs
tile_scheduler -> loop_counters_tile_status
loop_counters_tile_status -> block_addr_gen/systolic_fsm
systolic_fsm -> stream_ctrl/pair_stream_ctrl/array_ctrl/C控制/done_ctrl
array_ctrl -> skew_pipeline/pe_array/drain_controller
mac_status -> systolic_fsm/status_regs
done_ctrl -> start_ctrl/status_regs
status_regs/control_regs/buffer_access_ctrl -> mmio_if
```

### 7.2 A 数据路径

```text
block_addr_gen
 -> a_stream_ctrl
 -> buffer_access_ctrl
 -> npu_read_port_ctrl
 -> a_buffer
 -> a_prefetch_fifo
 -> pair_stream_ctrl
 -> a_input_unpacker
 -> a_bt_skew_pipeline
 -> pe_array
```

### 7.3 BT 数据路径

```text
block_addr_gen
 -> bt_stream_ctrl
 -> buffer_access_ctrl
 -> npu_read_port_ctrl
 -> bt_buffer
 -> bt_prefetch_fifo
 -> pair_stream_ctrl
 -> bt_input_unpacker
 -> a_bt_skew_pipeline
 -> pe_array
```

### 7.4 C 结果路径

```text
pe_array
 -> tile_result_collector
 -> output_reorder
 -> c_tile_acc_ctrl
 -> result_quantizer
 -> c_tile_write_ctrl
 -> c_write_fifo
 -> c_buffer
```

### 7.5 CPU Buffer 路径

```text
CPU -> mmio_if -> addr_decoder -> buffer_access_ctrl
    -> cpu_port_ctrl -> a_buffer/bt_buffer/c_buffer

a_buffer/bt_buffer/c_buffer -> CPU read response
    -> cpu_port_ctrl -> buffer_access_ctrl -> mmio_if -> CPU
```

图中为降低复杂度，用正向端口线和 `buffer_access_ctrl -> mmio_if` 响应线概括双向 RAM 读写接口。

## 8. 一次完整任务的运行过程

1. CPU 通过 MMIO 将 A 和转置后的 BT 写入对应 Buffer。
2. CPU 写入 M/N/K 和 TM/TN/TK。
3. CPU 写 `CTRL.start`，`start_ctrl` 锁存参数并产生 `start_pulse`。
4. `config_checker` 检查尺寸、tile 和 Buffer 容量。
5. `tile_scheduler` 初始化 tile_i、tile_j、tile_k。
6. `block_addr_gen` 计算当前 A、BT 和 C tile 地址。
7. A/BT stream controller 发起预取，数据进入两个 FIFO。
8. `pair_stream_ctrl` 等待 A、BT 同时有效，再成对送入 MAC。
9. unpacker 拆分 INT8，skew pipeline 形成波前。
10. `array_ctrl` 清零并启动 PE 阵列，PE 完成当前 K tile 的乘加。
11. 最后一对输入后，`drain_controller` 等待阵列排空。
12. `tile_result_collector` 和 `output_reorder` 输出 partial C tile。
13. `c_tile_acc_ctrl` 沿 tile_k 方向累加多个 partial tile。
14. 最后一个 K tile 完成后，结果经过量化器和写控制器进入 C 写 FIFO。
15. C 写 FIFO 将所有有效结果写入 C Buffer。
16. 若还有输出 tile，更新 tile_j/tile_i 后继续计算。
17. 最后一笔 C RAM 写完成后，`done_ctrl` 产生 `core_done`。
18. CPU 读取 DONE 和 C Buffer，最后写 `clear_done` 返回空闲状态。

## 9. 实现约束

- 所有模块共用 `clk` 和 `rst_n`；图中为避免拥挤，没有逐模块绘制。
- A/BT 必须作为原子数据对推进，任何一侧无效时都不能只推进另一侧。
- `valid=1 && ready=0` 时，发送方必须保持数据和 valid。
- 边界 tile 的越界元素在流控制侧补零，不能产生越界 RAM 地址。
- `array_done` 表示最后一个结果已经被接收，而不只是 PE 停止计算。
- `core_done` 表示最后一笔 C 数据已经写入 RAM，而不只是进入写 FIFO。
- `ACC_W` 必须覆盖最大 K 下的累加范围；写入 C Buffer 前明确舍入、饱和或截断策略。
- CPU 与 NPU 共享单端口 RAM 时，运行期间必须禁止 CPU 修改 Buffer。

## 10. 总结

该架构把软件控制、tile 调度、片上存储和阵列计算明确分开：

```text
npu_top    管 CPU 和访问仲裁
npu_ctrl   管地址、tile 和时间
npu_buffer 管数据保存、预取和写回
npu_mac    管波前、乘加、排空和结果输出
```

控制流从 CPU 向 MAC 前进，A/BT 数据从 Buffer 流向阵列，C 结果从阵列返回控制器后写入 Buffer，busy/done/error 状态最终回到 CPU。四条路径共同构成一套完整的矩阵乘法硬件闭环。
