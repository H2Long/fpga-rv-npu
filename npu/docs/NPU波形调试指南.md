# NPU 波形调试指南

本文档说明如何通过 VCD 波形判断当前 NPU 是否正常工作，以及出现错误时应该按什么顺序定位。内容以当前 `rtl/`、`tb/tb_npu.v` 和 `scripts/run_npu.py` 的实际层次为准。

## 1. 生成和打开波形

先重新运行测试台，确保波形和当前 RTL 一致：

```bash
cd npu
python3 scripts/run_npu.py
```

波形文件为：

```text
npu/sim/waves/npu_wave.vcd
```

用 GTKWave 打开：

```bash
gtkwave npu/sim/waves/npu_wave.vcd
```

当前测试台包含 10 项测试。第一次阅读建议从 T1 开始：

```text
T1：4x4x4 单 Tile，最容易观察
T2：16x16x16，多输出 Tile、多 K Tile 累加
T3：6x7x9，边界补零
T4：5x5x6，非标准 Tile 尺寸
T5：8x8x8，负数和量化
T6~T10：配置错误路径
```

## 2. RTL 层次结构

VCD 的顶层实例为：

```text
tb_npu.dut
├── u_npu_top
├── u_npu_ctrl
├── u_npu_buffer
└── u_npu_mac
```

常用子层次：

```text
tb_npu.dut.u_npu_top.u_mmio_if
tb_npu.dut.u_npu_top.u_control_regs
tb_npu.dut.u_npu_top.u_start_ctrl
tb_npu.dut.u_npu_ctrl.u_systolic_fsm
tb_npu.dut.u_npu_ctrl.u_tile_scheduler
tb_npu.dut.u_npu_ctrl.u_block_addr_gen
tb_npu.dut.u_npu_ctrl.u_c_tile_acc_ctrl
tb_npu.dut.u_npu_ctrl.u_c_tile_write_ctrl
tb_npu.dut.u_npu_ctrl.u_done_ctrl
tb_npu.dut.u_npu_buffer.u_a_buffer.u_ram
tb_npu.dut.u_npu_buffer.u_bt_buffer.u_ram
tb_npu.dut.u_npu_buffer.u_c_buffer.u_ram
tb_npu.dut.u_npu_buffer.u_a_prefetch_fifo.u_fifo
tb_npu.dut.u_npu_buffer.u_bt_prefetch_fifo.u_fifo
tb_npu.dut.u_npu_buffer.u_c_write_fifo.u_fifo
tb_npu.dut.u_npu_mac.u_a_input_unpacker
tb_npu.dut.u_npu_mac.u_bt_input_unpacker
tb_npu.dut.u_npu_mac.u_skew
tb_npu.dut.u_npu_mac.u_pe_array.u_pe00
tb_npu.dut.u_npu_mac.u_pe_array.u_pe11
tb_npu.dut.u_npu_mac.u_pe_array.u_pe33
tb_npu.dut.u_npu_mac.u_drain_controller
tb_npu.dut.u_npu_mac.u_tile_result_collector
tb_npu.dut.u_npu_mac.u_mac_status
```

## 3. 推荐的 GTKWave 信号分组

### 3.1 复位和 MMIO

```text
tb_npu.dut.clk
tb_npu.dut.rst
tb_npu.dut.cpu_valid
tb_npu.dut.cpu_we
tb_npu.dut.cpu_addr
tb_npu.dut.cpu_wdata
tb_npu.dut.cpu_ready
tb_npu.dut.cpu_rdata
```

### 3.2 任务控制

```text
tb_npu.dut.start_pulse
tb_npu.dut.core_busy
tb_npu.dut.core_done
tb_npu.dut.error_code
tb_npu.dut.u_npu_ctrl.u_systolic_fsm.state
tb_npu.dut.u_npu_ctrl.tile_i
tb_npu.dut.u_npu_ctrl.tile_j
tb_npu.dut.u_npu_ctrl.tile_k
tb_npu.dut.u_npu_ctrl.valid_tm
tb_npu.dut.u_npu_ctrl.valid_tn
tb_npu.dut.u_npu_ctrl.valid_tk
```

### 3.3 A/BT 预取

```text
tb_npu.dut.npu_a_addr
tb_npu.dut.npu_a_re
tb_npu.dut.u_npu_buffer.a_ram_raddr
tb_npu.dut.u_npu_buffer.a_ram_re
tb_npu.dut.u_npu_buffer.a_ram_rdata
tb_npu.dut.u_npu_buffer.a_fifo_push
tb_npu.dut.u_npu_buffer.a_fifo_valid
tb_npu.dut.u_npu_buffer.a_fifo_count
tb_npu.dut.u_npu_buffer.a_fifo_pop
tb_npu.dut.npu_bt_addr
tb_npu.dut.npu_bt_re
tb_npu.dut.u_npu_buffer.bt_ram_raddr
tb_npu.dut.u_npu_buffer.bt_ram_re
tb_npu.dut.u_npu_buffer.bt_ram_rdata
tb_npu.dut.u_npu_buffer.bt_fifo_push
tb_npu.dut.u_npu_buffer.bt_fifo_valid
tb_npu.dut.u_npu_buffer.bt_fifo_count
tb_npu.dut.u_npu_buffer.bt_fifo_pop
```

### 3.4 MAC 输入和握手

```text
tb_npu.dut.a_stream_valid
tb_npu.dut.a_stream_data
tb_npu.dut.bt_stream_valid
tb_npu.dut.bt_stream_data
tb_npu.dut.a_stream_ready
tb_npu.dut.bt_stream_ready
tb_npu.dut.u_npu_ctrl.pair_fire
tb_npu.dut.array_start
tb_npu.dut.array_enable
tb_npu.dut.array_clear_acc
tb_npu.dut.array_flush
```

### 3.5 PE 和波前

先观察 `u_pe00`、`u_pe11`、`u_pe33` 三个代表性 PE：

```text
u_pe00.a_in       u_pe00.a_v_in       u_pe00.bt_in       u_pe00.bt_v_in       u_pe00.acc
u_pe11.a_in       u_pe11.a_v_in       u_pe11.bt_in       u_pe11.bt_v_in       u_pe11.acc
u_pe33.a_in       u_pe33.a_v_in       u_pe33.bt_in       u_pe33.bt_v_in       u_pe33.acc
```

同时观察 `u_a_input_unpacker.lane0..lane3`、`u_bt_input_unpacker.lane0..lane3`、`u_skew.a_sk0..a_sk3`、`u_skew.bt_sk0..bt_sk3` 及对应 valid。

### 3.6 排空和结果收集

```text
tb_npu.dut.u_npu_mac.u_drain_controller.cnt
tb_npu.dut.u_npu_mac.u_drain_controller.drain_done
tb_npu.dut.u_npu_mac.u_tile_result_collector.state
tb_npu.dut.u_npu_mac.u_tile_result_collector.idx
tb_npu.dut.u_npu_mac.u_tile_result_collector.c_result_valid
tb_npu.dut.u_npu_mac.u_tile_result_collector.c_result
tb_npu.dut.u_npu_mac.u_tile_result_collector.c_scan_index
tb_npu.dut.u_npu_mac.u_tile_result_collector.collect_done
tb_npu.dut.array_done
```

### 3.7 C 写回和完成

```text
tb_npu.dut.cwr_valid
tb_npu.dut.cwr_ready
tb_npu.dut.cwr_addr
tb_npu.dut.cwr_data
tb_npu.dut.u_npu_buffer.c_wr_pulse
tb_npu.dut.u_npu_buffer.cwf_we
tb_npu.dut.u_npu_buffer.cwf_addr
tb_npu.dut.u_npu_buffer.cwf_data
tb_npu.dut.u_npu_ctrl.u_done_ctrl.wr_cnt
tb_npu.dut.u_npu_ctrl.u_done_ctrl.done_seen
tb_npu.dut.core_done
```

## 4. 正常任务的波形顺序

一笔正常任务应当呈现以下因果链：

```text
复位释放
  -> MMIO 写入 M/N/K/TM/TN/TK/qshift
  -> CTRL.start
  -> start_pulse 单拍
  -> FSM 离开 IDLE
  -> cfg_ok=1
  -> prefetch_go
  -> A/BT RAM 连续读
  -> A/BT FIFO count 增加
  -> feed_go 和 pair_fire
  -> array_start
  -> array_enable
  -> array_flush/drain
  -> 16 个 C 结果有效
  -> C Tile 累加和量化
  -> C FIFO 写入
  -> c_wr_pulse
  -> core_done
```

其中：

- `array_done` 表示当前 K Tile 的 16 个阵列结果已经收集完。
- `core_done` 表示整个矩阵的有效 C 元素已经写入 C Buffer。
- 两者不是同一个完成事件。

## 5. MMIO 波形检查

启动时应看到：

```text
cpu_addr = 0x00000000
cpu_wdata[0] = 1
start_req = 1
start_pulse = 1
```

`start_pulse` 应只持续一个时钟周期。如果 CPU 请求变化但 `req_valid` 没有出现，检查 `mmio_if`；如果 `req_valid` 出现但 `start_req` 没有出现，检查 `addr_decoder` 和 CTRL 写入。

常用配置地址：

```text
0x04 M
0x08 N
0x0C K
0x10 TM
0x14 TN
0x18 TK
0x1C qshift
```

当前控制寄存器只接受 `req_byte_en[0]` 有效的配置写入。波形中应确认写入时低字节使能为 1。

## 6. Buffer 和 FIFO 的正常特征

T1 的 `TK=4`，因此预取期间应看到：

```text
A FIFO count：0 -> 1 -> 2 -> 3 -> 4
BT FIFO count：0 -> 1 -> 2 -> 3 -> 4
```

RAM 读请求和返回数据相差一个时钟周期。`a_fifo_push`/`bt_fifo_push` 应在 RAM 数据有效的周期出现。

如果 A FIFO 增长而 BT FIFO 不增长，优先检查 `bt_addr`、`bt_re`、`bt_ram_rdata` 和 `bt_fifo_push`。如果 FIFO count 一直为零，优先检查 RAM 读使能和 `npu_read_port_ctrl`。

## 7. A/BT 成对传输

`pair_fire` 必须同时满足：

```text
feed_go = 1
a_fifo_valid = 1
bt_fifo_valid = 1
a_stream_ready = 1
bt_stream_ready = 1
```

在 `pair_fire=1` 的同一周期，应该看到：

```text
a_fifo_pop = 1
bt_fifo_pop = 1
a_stream_valid = 1
bt_stream_valid = 1
```

如果两侧 pop 不同步，A 和 BT 的 K 序列已经错位。

## 8. 拆包与波前检查

一个 32 位字拆为：

```text
lane0 = data[7:0]
lane1 = data[15:8]
lane2 = data[23:16]
lane3 = data[31:24]
```

波前延迟应为：

```text
A 行 0：延迟 0 拍    A 行 1：延迟 1 拍
A 行 2：延迟 2 拍    A 行 3：延迟 3 拍
BT 列 0：延迟 0 拍   BT 列 1：延迟 1 拍
BT 列 2：延迟 2 拍   BT 列 3：延迟 3 拍
```

数据和 valid 必须一起延迟。如果数据已经延迟但 valid 没有同步移动，PE 会在错误周期累加。

## 9. PE 阵列检查

每个 PE 的正常条件是：

```text
clear_acc=1 -> acc 清零
enable=1    -> A/BT 向右/向下传播
a_v_in=1 且 bt_v_in=1 -> acc 增加一次乘积
```

T1 中 K=4，因此有效 PE 最终应完成 4 次乘加。建议先观察 `u_pe00`、`u_pe11` 和 `u_pe33`，不要一开始把 16 个 PE 全部加入波形窗口。

如果 PE00 正常而 PE33 不变，检查 skew 延迟和阵列横向/纵向连接；如果所有 PE 的 acc 都不变，检查 `pair_fire`、`array_enable` 和 skew valid。

## 10. 排空和结果收集

最后一次 `pair_fire` 之后，正常顺序是：

```text
array_flush = 1
drain_done = 1
c_result_valid 连续 16 拍
c_scan_index = 0,1,2,...,15
collect_done 延后一拍出现
array_done 随后出现
```

如果 `drain_done` 不出现，检查 `array_flush`、`array_enable` 和 drain counter。如果排空完成但结果不完整，检查 collector 的 `state`、`idx` 和 `acc_flat`。

## 11. C 写回检查

写回阶段应看到：

```text
write_go = 1
idx 从 0 扫描到 15
有效 lane 才有 cwr_valid
cwr_ready=1 时进入 C 写 FIFO
c_wr_pulse 表示真正写入 C RAM
```

T3 的参数为 `M=6,N=7,TM=4,TN=4`，四个输出 Tile 的有效元素数量为：

```text
4x4 + 4x3 + 2x4 + 2x3 = 42
```

因此 T3 应看到 42 个 `c_wr_pulse`。数量过多时检查 `valid_tm/valid_tn` 和 `cwr_valid`；数量过少时检查 `cwr_ready`、C 写 FIFO 和 `write_done`。

## 12. 分模块定位故障

| 波形现象 | 优先检查 |
|---|---|
| CPU 写配置但参数不变 | `mmio_if`、`addr_decoder`、`control_regs` |
| start 没产生 | CTRL 地址、`req_byte_en[0]`、`start_req` |
| FSM 卡在预取 | A/BT `*_re`、RAM 返回、FIFO push/count |
| A/BT FIFO 数量不一致 | `npu_read_port_ctrl`、RAM 地址和 FIFO |
| `pair_fire` 不出现 | 两侧 FIFO valid、ready、`feed_go` |
| PE 输入有效但 acc 不变 | PE valid、`clear_acc`、`enable` |
| PE00 正常而远端 PE 错 | skew 延迟和 PE 阵列连接 |
| `drain_done` 不出现 | `array_flush`、`array_enable`、排空计数 |
| 16 个结果不完整 | collector state、idx、acc_flat |
| C 结果正确但 Buffer 错 | quantizer、C 地址、C FIFO |
| DONE 提前出现 | `c_wr_pulse`、`done_ctrl.wr_cnt` |
| 边界结果错误 | `valid_tm`、`valid_tn`、lane_en |
| 量化结果错误 | qshift、signed acc、result_quantizer |

## 13. 推荐的 GTKWave 波形组

### `00_reset_mmio`

```text
clk rst cpu_valid cpu_we cpu_addr cpu_wdata cpu_ready cpu_rdata
```

### `01_task_control`

```text
start_pulse core_busy core_done error_code
systolic_fsm.state tile_i tile_j tile_k valid_tm valid_tn valid_tk
```

### `02_prefetch`

```text
npu_a_addr npu_a_re a_fifo_push a_fifo_valid a_fifo_count a_fifo_pop
npu_bt_addr npu_bt_re bt_fifo_push bt_fifo_valid bt_fifo_count bt_fifo_pop
```

### `03_mac_input`

```text
a_stream_valid a_stream_data bt_stream_valid bt_stream_data
a_stream_ready bt_stream_ready pair_fire
array_start array_enable array_clear_acc array_flush
```

### `04_pe`

```text
u_pe00.acc u_pe11.acc u_pe33.acc
```

### `05_result_writeback`

```text
drain_done c_result_valid c_result c_scan_index
collect_done array_done cwr_valid cwr_ready cwr_addr cwr_data c_wr_pulse core_done
```

## 14. 阅读原则

不要一开始观察所有信号。按照下面的因果链逐段确认：

```text
CPU 启动
-> 参数锁存
-> FSM 推进
-> A/BT 地址产生
-> RAM 返回数据
-> FIFO 入队
-> A/BT 成对弹出
-> skew 波前传播
-> PE 累加
-> 阵列排空
-> 结果收集
-> C Tile 累加/量化
-> C FIFO
-> C RAM 写入
-> core_done
```

某一段没有发生时，只检查这一段的输入和输出，不要越过故障点直接分析后面的模块。

## 15. 最小观察信号集合

如果只想快速判断一次任务是否正常，先加入下面这些信号：

```text
tb_npu.dut.start_pulse
tb_npu.dut.core_busy
tb_npu.dut.core_done
tb_npu.dut.error_code

tb_npu.dut.u_npu_ctrl.u_systolic_fsm.state
tb_npu.dut.u_npu_ctrl.u_systolic_fsm.prefetch_go
tb_npu.dut.u_npu_ctrl.u_systolic_fsm.feed_go
tb_npu.dut.u_npu_ctrl.u_systolic_fsm.pair_fire
tb_npu.dut.u_npu_ctrl.u_systolic_fsm.drain_en
tb_npu.dut.u_npu_ctrl.u_systolic_fsm.write_go

tb_npu.dut.u_npu_buffer.a_fifo_count
tb_npu.dut.u_npu_buffer.bt_fifo_count
tb_npu.dut.a_stream_data
tb_npu.dut.bt_stream_data
tb_npu.dut.array_enable

tb_npu.dut.u_npu_mac.u_pe_array.u_pe00.acc
tb_npu.dut.u_npu_mac.u_pe_array.u_pe11.acc
tb_npu.dut.u_npu_mac.u_pe_array.u_pe33.acc

tb_npu.dut.u_npu_mac.u_tile_result_collector.c_result_valid
tb_npu.dut.u_npu_buffer.c_wr_pulse
```

判断顺序固定为：

```text
启动
→ FSM
→ A/BT FIFO
→ pair_fire
→ PE acc
→ 结果收集
→ C 写回
→ core_done
```

哪一级没有发生，就只检查该级及其前一级，不要直接跳到后面的结果信号。
