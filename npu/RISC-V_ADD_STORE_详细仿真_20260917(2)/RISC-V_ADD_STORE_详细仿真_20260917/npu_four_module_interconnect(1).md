# NPU 四大模块接线总结

## 1. 模块职责

```text
npu_top    CPU MMIO、控制/状态寄存器、启动和访问仲裁
npu_ctrl   tile 调度、地址生成、脉动阵列时序
npu_buffer A/BT/C 片上 Buffer、预取 FIFO、结果写回
npu_mac    P×Q PE 阵列、乘加、排空和结果收集
```

核心边界是：`npu_top` 管理 CPU，`npu_ctrl` 管理时间和地址，`npu_buffer` 管理存储，`npu_mac` 管理计算。

## 2. 总体接线

```text
CPU ──MMIO──► npu_top ──start/参数──► npu_ctrl
  ▲             │                         │
  │             │busy/done                │A/BT/C地址、阵列控制
  │             ▼                         ▼
  └────读数据── npu_buffer ◄──────────► npu_mac
                  │ A/BT数据      C结果 │
                  └───────────────┘
```

准确的数据路径是：

```text
A Buffer ──A stream──► npu_mac
BT Buffer ─BT stream─► npu_mac
npu_mac ──C 结果流─► npu_ctrl 累加/写回 ──► C Buffer
```

## 3. `npu_top` 接口

CPU 侧：`cpu_addr[31:0]`、`cpu_wdata[31:0]`、`cpu_rdata[31:0]`、`cpu_byte_en[3:0]`、`cpu_we`、`cpu_valid`、`cpu_ready`。

与 `npu_ctrl`：

```text
npu_top → npu_ctrl：start_pulse、cfg_m/cfg_n/cfg_k、TM/TN/TK、clear_done
npu_ctrl → npu_top：core_busy、core_done、error_flag（可选）
```

M/N/K 建议为 6 位；控制和状态信号为 1 位。

与 Buffer 的 CPU 端口：A/BT 地址 6 位，C 地址 8 位，数据 32 位，读写使能 1 位。

## 4. `npu_ctrl` → `npu_buffer`

`npu_ctrl` 是计算访问主控，输出：

```text
a_addr[5:0]、a_rd_en
bt_addr[5:0]、bt_rd_en
c_addr[7:0]、c_we、c_wdata[31:0]
```

`npu_buffer` 返回：

```text
a_rdata[31:0]、a_rvalid
bt_rdata[31:0]、bt_rvalid
c_write_ready（可选）
```

实际建议的连接为：

```text
npu_ctrl → npu_buffer.a/BT读端口
npu_ctrl 负责 C tile 累加和写回；`npu_mac` 只返回结果流，不直接连接 C Buffer。
```

## 5. `npu_buffer` → `npu_mac`

A 数据路径：

```text
A Buffer → A prefetch FIFO → a_stream_data[31:0]/valid/ready → npu_mac
```

BT 数据路径：

```text
BT Buffer → BT prefetch FIFO → bt_stream_data[31:0]/valid/ready → npu_mac
```

C 结果路径：

```text
npu_mac → c_result 流 → npu_ctrl 的 C tile 累加器 → C Buffer
```

结果采用串行流：`c_result[ACC_W-1:0]`、`c_result_index`、`c_result_valid`、`c_result_last`；地址和写使能统一由 `npu_ctrl` 产生。

## 6. `npu_ctrl` ↔ `npu_mac`

控制信号由 `npu_ctrl` 输出到 `npu_mac`：

```text
array_start、array_enable、array_clear_acc
array_flush、array_last
```

全部为 1 位。数据流握手为：

```text
npu_ctrl/stream_ctrl → a_stream_valid、bt_stream_valid
npu_mac → a_stream_ready、bt_stream_ready
```

完成和结果返回：

```text
npu_mac → npu_ctrl：array_ready、array_busy、array_done
npu_mac → npu_ctrl：c_result、c_result_index、c_result_valid、c_result_last
```

`array_done` 到达后，`npu_ctrl` 收完结果流，决定继续下一个 `tile_k`，或写回完整 C tile 并更新 `tile_i/tile_j`。

## 7. `npu_buffer` 内部结构

```text
npu_buffer
├── a_buffer_ram       64×32 bit
├── bt_buffer_ram      64×32 bit
├── c_buffer_ram       256×32 bit
├── cpu_port_ctrl
├── npu_read_port_ctrl
├── mac_write_port_ctrl
├── a_prefetch_fifo
├── bt_prefetch_fifo
└── c_write_fifo
```

`core_busy=0` 时允许 CPU 访问 Buffer；`core_busy=1` 时 NPU 优先读取 A/BT 和写入 C，CPU 不允许修改 Buffer。

## 8. 控制流

```text
CPU 写 M/N/K
 → npu_top.control_regs
 → npu_top.start_ctrl
 → npu_ctrl.tile_scheduler
 → npu_ctrl.systolic_fsm
 → npu_mac.array_control
```

完成反馈：

```text
npu_mac.array_done
 → npu_ctrl.done_ctrl
 → npu_top.start_ctrl
 → npu_top.status_regs
 → CPU 读取 DONE
```

## 9. 数据流

### 输入装载

```text
CPU → npu_top → buffer_access_ctrl → A/BT Buffer
```

### 计算

```text
npu_ctrl → npu_buffer：A/BT地址
npu_buffer → npu_mac：A/BT数据流
npu_mac：PE乘法、部分和、阵列传播
npu_mac → npu_ctrl：C 结果流；npu_ctrl → npu_buffer：C 写地址/数据/使能
```

### 结果读取

```text
CPU → npu_top → buffer_access_ctrl → C Buffer → npu_top → CPU
```

## 10. 一次 tile 的时序

```text
1. CPU 配置 M/N/K 并装载 A、BT Buffer。
2. CPU 写 start，npu_top 产生 start_pulse。
3. npu_ctrl 锁存参数并选择 tile_i/tile_j/tile_k。
4. npu_ctrl 生成 A、BT、C tile 地址。
5. npu_buffer 预取 A/BT tile，送入 FIFO。
6. npu_mac 拆分数据并按波前注入 PE 阵列。
7. A 向右传播，BT 向下传播，PE 完成乘加。
8. 输入结束后 array_flush，等待阵列排空。
9. C tile 部分结果沿 K 方向累加。
10. 最后一个 K tile 完成后写入 C Buffer。
11. 最后一个 tile 完成后 npu_ctrl 产生 core_done。
12. npu_top 置 DONE，CPU 读取 C Buffer 并清除 DONE。
```

## 11. 四模块接口总表

| 连接 | 主要信号 | 典型位宽 |
|---|---|---:|
| CPU ↔ `npu_top` | 地址、读写数据、握手 | 地址/数据 32，字节使能 4 |
| `npu_top` ↔ `npu_ctrl` | start、M/N/K、TM/TN/TK、busy、done | 参数 6，控制 1 |
| `npu_ctrl` ↔ `npu_buffer` | A/BT/C 地址和读写控制 | A/BT 地址 6，C 地址 8 |
| `npu_buffer` ↔ `npu_mac` | A/BT 流、C 结果 | 数据 32，valid/ready 1 |
| `npu_ctrl` ↔ `npu_mac` | 阵列启动、清零、排空、完成 | 控制 1 |

## 12. 总结

```text
npu_top    = CPU控制平面
npu_ctrl   = tile调度和时序控制平面
npu_buffer = 数据存储和搬运平面
npu_mac    = 脉动阵列计算平面
```

四者通过“控制流”和“数据流”分工协作：控制流从 `npu_top → npu_ctrl → npu_mac`，A/BT 数据流从 `npu_buffer → npu_mac`，C 结果流从 `npu_mac → npu_ctrl → npu_buffer`，状态流从 `npu_mac → npu_ctrl → npu_top → CPU`。
