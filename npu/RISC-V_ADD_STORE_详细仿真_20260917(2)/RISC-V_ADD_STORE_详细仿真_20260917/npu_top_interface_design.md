# NPU Top 模块接口与数据流设计

## 1. 范围与模块划分

`npu_top` 由以下六个模块组成：

```text
npu_top
├── mmio_if                 CPU MMIO 接口
├── addr_decoder            地址译码器
├── control_regs            控制寄存器
├── status_regs             状态寄存器
├── start_ctrl              启动/完成控制器
└── buffer_access_ctrl      Buffer 访问控制器
```

`npu_ctrl`、`npu_buffer` 和 `npu_mac` 是 `npu_top` 外部的计算模块，由顶层连接。

## 2. 总体连接关系

```text
CPU ──MMIO──► mmio_if ──请求总线──► addr_decoder
                                      ├──► control_regs ──► start_ctrl ──► npu_ctrl
                                      ├──► status_regs ◄──── busy/done
                                      └──► buffer_access_ctrl ──► A/BT/C Buffer

npu_ctrl ──地址/读写控制──► buffer_access_ctrl
A/BT Buffer ──32位数据──► npu_mac
npu_mac ──C结果──► buffer_access_ctrl ──► C Buffer
```

其中：

- `mmio_if` 只处理 CPU 总线协议；
- `addr_decoder` 只判断访问目标；
- `control_regs` 保存参数和命令；
- `start_ctrl` 管理启动、运行和完成状态；
- `status_regs` 将内部状态提供给 CPU；
- `buffer_access_ctrl` 汇合 CPU 访问端口与 NPU 计算端口。

## 3. 接口和位宽

| 信号 | 位宽 | 说明 |
|---|---:|---|
| `cpu_addr` | 32 | CPU MMIO 字节地址 |
| `cpu_wdata/cpu_rdata` | 32 | CPU 写入/读取数据 |
| `cpu_byte_en` | 4 | 32 位数据的字节使能 |
| `cpu_we/cpu_valid/cpu_ready` | 1 | 读写、请求有效、完成响应 |
| `M/N/K` | 6（建议） | 矩阵维度参数 |
| A、BT 地址 | 6 | A、BT 为 64×32 bit |
| C 地址 | 8 | C 为 256×32 bit |
| Buffer 数据 | 32 | RAM 数据宽度 |
| `start/busy/done/we/re` | 1 | 控制信号 |

CPU 使用字节地址，Buffer 使用 32 位字地址，因此：

```text
A/BT 地址 = (CPU地址 - BASE) >> 2，取 [5:0]
C 地址    = (CPU地址 - BASE) >> 2，取 [7:0]
```

## 4. `mmio_if`

### 连接

```text
CPU → mmio_if:
    cpu_addr[31:0], cpu_wdata[31:0], cpu_byte_en[3:0]
    cpu_we, cpu_valid

mmio_if → 后级:
    req_addr[31:0], req_wdata[31:0], req_byte_en[3:0]
    req_we, req_valid

后级 → mmio_if:
    control_rdata[31:0], status_rdata[31:0], buffer_rdata[31:0]

mmio_if → CPU:
    cpu_rdata[31:0], cpu_ready
```

### 职责

- 接收和锁存 CPU 的一次读写请求；
- 产生内部请求；
- 复用控制寄存器、状态寄存器和 Buffer 的读数据；
- 为同步 RAM 读操作处理等待周期。

同步 RAM 读可以是 `T0` 接收地址、`T1` RAM 返回数据、`T2` 输出 `cpu_rdata` 并拉高 `cpu_ready`。

## 5. `addr_decoder`

输入：

```text
req_addr[31:0], req_we, req_valid
```

输出：

```text
ctrl_sel, status_sel, a_buf_sel, bt_buf_sel, c_buf_sel
a_local_addr[5:0], bt_local_addr[5:0], c_local_addr[7:0]
```

建议地址空间：

| 地址范围 | 目标 |
|---|---|
| `0x0000_0000~0x0000_000F` | 控制寄存器 |
| `0x0000_0010~0x0000_001F` | 状态寄存器 |
| `0x0000_1000~0x0000_10FF` | A Buffer |
| `0x0000_2000~0x0000_20FF` | BT Buffer |
| `0x0000_3000~0x0000_33FF` | C Buffer |

`addr_decoder` 只产生片选和局部地址，不保存寄存器，也不参与 MAC 运算。

## 6. `control_regs`

输入来自 `mmio_if/addr_decoder`：

```text
ctrl_sel, req_we, req_addr[31:0], req_wdata[31:0], req_byte_en[3:0]
```

输出到 `start_ctrl`：

```text
cfg_m[5:0], cfg_n[5:0], cfg_k[5:0]
start_req, clear_done_req
```

读数据返回路径：

```text
control_regs → control_rdata[31:0] → mmio_if → CPU
```

建议寄存器：

| 偏移 | 名称 | 有效位 |
|---:|---|---|
| `0x00` | `CTRL` | bit0=`start`，bit1=`clear_done` |
| `0x04` | `M_CFG` | bit[5:0] |
| `0x08` | `N_CFG` | bit[5:0] |
| `0x0C` | `K_CFG` | bit[5:0] |

该模块只保存配置，不直接驱动 `npu_mac`。

## 7. `start_ctrl`

输入：

```text
control_regs → start_req, clear_done_req, cfg_m, cfg_n, cfg_k
npu_ctrl     → core_busy, core_done
```

输出：

```text
start_pulse
cfg_m_latched[5:0], cfg_n_latched[5:0], cfg_k_latched[5:0]
busy_status, done_status
```

输出连接到：

```text
start_pulse/锁存参数 → npu_ctrl
busy_status/done_status → status_regs
```

状态机：

```text
IDLE --start_req && !core_busy--> RUNNING --core_done--> DONE
 DONE --clear_done_req--> IDLE
```

启动时序：

```text
T0：CPU 写 CTRL.start
T1：control_regs 产生 start_req
T2：start_ctrl 锁存 M/N/K，输出单周期 start_pulse
T3：npu_ctrl 接收 start_pulse，开始计算
```

## 8. `status_regs`

输入：

```text
busy_status      ← start_ctrl
done_status      ← start_ctrl
buffer_ready     ← buffer_access_ctrl
error_flag       ← 错误检测逻辑
```

输出：

```text
status_rdata[31:0] → mmio_if → CPU
```

建议状态位：

| 位 | 名称 | 含义 |
|---:|---|---|
| bit0 | `BUSY` | NPU 正在计算 |
| bit1 | `DONE` | 计算完成 |
| bit2 | `ERROR` | 访问或计算错误 |
| bit3 | `BUFFER_READY` | 输入数据已装载 |

## 9. `buffer_access_ctrl`

该模块有三侧连接：CPU 访问侧、NPU 计算侧和实际 RAM 侧。

### CPU 访问侧

```text
a_buf_sel, bt_buf_sel, c_buf_sel
a_local_addr[5:0], bt_local_addr[5:0], c_local_addr[7:0]
req_wdata[31:0], req_we, req_valid, req_byte_en[3:0]
```

### NPU 计算侧

```text
npu_a_addr[5:0], npu_a_re
npu_bt_addr[5:0], npu_bt_re
npu_c_addr[7:0], npu_c_we, npu_c_wdata[31:0]
```

这些地址和读写控制由 `npu_ctrl` 产生，C 的写数据通常来自 `npu_mac`。

### RAM 侧

```text
A :  a_addr[5:0],  a_wdata[31:0],  a_we,  a_re,  a_rdata[31:0]
BT:  bt_addr[5:0], bt_wdata[31:0], bt_we, bt_re, bt_rdata[31:0]
C :  c_addr[7:0],  c_wdata[31:0],  c_we,  c_re,  c_rdata[31:0]
```

### 访问策略

```text
core_busy=1：NPU 端口优先，CPU 不允许写 Buffer
core_busy=0：CPU 可通过 MMIO 访问 Buffer
```

因此，该模块负责地址转换、端口选择、访问仲裁和读数据复用，不等同于 RAM 本身。

## 10. `npu_ctrl` 与 `npu_mac`

### 控制连接

```text
npu_ctrl → npu_mac:
    mac_start, mac_valid, acc_clear, acc_enable, acc_last

npu_mac → npu_ctrl:
    mac_busy, mac_ready, mac_done
    c_result_valid, c_result[31:0]
```

### A/BT 数据连接

```text
npu_ctrl ──a_addr[5:0]──► buffer_access_ctrl ──► A Buffer
npu_ctrl ─bt_addr[5:0]──► buffer_access_ctrl ──► BT Buffer

A Buffer  ──a_rdata[31:0]──┐
                           ├──► npu_mac
BT Buffer ─bt_rdata[31:0]──┘
```

每个 32 位字可以拆成四个有符号 INT8 数据。

### C 写回连接

```text
npu_mac
  ├─ c_result[31:0]
  ├─ c_result_valid
  └─ c_addr[7:0]
          ↓
buffer_access_ctrl
          ↓
C Buffer
```

## 11. 一次计算的数据流

### 11.1 配置和装载

```text
CPU → mmio_if → addr_decoder → control_regs
CPU → mmio_if → addr_decoder → buffer_access_ctrl → A/BT Buffer
```

CPU 写入 M、N、K、启动控制位以及 A/BT 输入数据。

### 11.2 启动

```text
CPU → mmio_if → addr_decoder → control_regs
    → start_ctrl → npu_ctrl
```

传输内容为 `start_pulse` 和锁存后的 M/N/K。

### 11.3 计算和写回

```text
npu_ctrl
  → buffer_access_ctrl
  → A/BT Buffer
  → npu_mac
  → buffer_access_ctrl
  → C Buffer
```

详细步骤：

1. `npu_ctrl` 产生 A、BT 地址；
2. `buffer_access_ctrl` 选择 NPU 端口；
3. A、BT Buffer 返回 32 位数据；
4. `npu_mac` 完成四路 INT8 乘法、求和和累加；
5. `npu_mac` 输出 C 结果；
6. `buffer_access_ctrl` 将结果写入 C Buffer；
7. `npu_ctrl` 更新 `i/j/k` 索引并继续循环。

### 11.4 完成和读取

```text
npu_ctrl → start_ctrl → status_regs → mmio_if → CPU
```

完成后：

```text
BUSY: 1 → 0
DONE: 0 → 1
```

CPU 读取 C Buffer 的路径为：

```text
CPU → mmio_if → addr_decoder → buffer_access_ctrl
    → C Buffer → buffer_access_ctrl → mmio_if → CPU
```

最后 CPU 写 `clear_done`，`start_ctrl` 清除完成状态并回到 `IDLE`。

## 12. 关键连接清单

```text
mmio_if          → addr_decoder
addr_decoder     → control_regs / status_regs / buffer_access_ctrl
control_regs     → start_ctrl
start_ctrl       → npu_ctrl / status_regs
npu_ctrl         → buffer_access_ctrl / npu_mac
buffer_access_ctrl → A Buffer / BT Buffer / C Buffer
npu_mac          → buffer_access_ctrl → C Buffer
```

CPU 只参与配置、启动、状态查询和结果读取；计算期间的地址生成、Buffer 读取、MAC 运算、累加和 C 写回由 NPU 硬件自动完成。
