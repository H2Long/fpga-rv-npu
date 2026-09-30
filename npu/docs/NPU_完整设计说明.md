# NPU INT8 矩阵乘法加速器 — RTL 实现说明

本文档对应 `npu/` 目录下的完整 RTL 实现，是当前 NPU 设计、接口、模块职责、时序和验证信息的唯一说明入口。内容以当前 `rtl/`、`tb/` 和 `scripts/` 为准，共覆盖 45 个 RTL 文件。

## 1. 功能

有符号 INT8 矩阵乘法:`C[M][N] = A[M][K] × BT[N][K]`(B 预先转置为 BT 存入)。

- 4×4 输出驻留式脉动阵列(P=Q=4),PE 累加器 32 位
- A/BT Buffer 64×32 bit,C Buffer 256×32 bit(一个 32 位字存一个 C 元素)
- 三层 tile 循环(tile_i/tile_j/tile_k),TM/TN ≤ 4,TK ≤ min(K, 16)
- 边界 tile 越界行/列在 unpacker 侧补零,越界 k 不读取,越界 C 项不写回
- K 方向部分和在 `c_tile_acc_ctrl` 中累加;最后经舍入/饱和量化写入 C Buffer
- CPU 通过 MMIO 配置、启动、查询状态、装载/读取 Buffer;运行期间(core_busy=1)CPU 端口被封锁

## 2. 目录结构

```text
npu/
├── rtl/                     45 个 Verilog-2001 文件，按功能平面分组
│   ├── common/               公共宏定义、RAM、FIFO 和流控制
│   ├── top/                  系统顶层和 CPU/MMIO 控制
│   ├── ctrl/                 Tile 调度、阵列时序和 C 写回
│   ├── buffer/               A/BT/C Buffer 和数据搬运
│   └── mac/                  INT8 拆包、PE 阵列和结果收集
├── tb/tb_npu.v              测试台(CPU 行为模型 + 10 项自校验测试)
├── scripts/                 仿真与绘图脚本
├── docs/                    设计说明
├── sim/                     编译产物、日志和波形
│   ├── build/tb_npu.vvp     可由脚本重建的仿真执行文件
│   ├── logs/                compile.log / npu_sim.log
│   └── waves/               npu_wave.vcd
└── figures/                 三张 PNG + SVG
```

45 个 RTL 文件包含系统顶层、功能模块和通用基元；另有公共宏头文件 `npu_defines.vh`。

## 3. MMIO 寄存器

| 地址 | 寄存器 | 说明 |
|---|---|---|
| `0x0000_0000` | `CTRL` | bit0=`start`,bit1=`clear_done` |
| `0x0000_0004` | `M_CFG` | M,6 位 |
| `0x0008` | `N_CFG` | N,6 位 |
| `0x000C` | `K_CFG` | K,6 位 |
| `0x0010` | `TM_CFG` | 行 tile 尺寸,1..4 |
| `0x0014` | `TN_CFG` | 列 tile 尺寸,1..4 |
| `0x0018` | `TK_CFG` | K 方向 tile 尺寸,1..min(K,16) |
| `0x001C` | `QUANT_CFG` | 结果右移位数(0=直通) |
| `0x0020` | `STATUS` | bit0 BUSY / bit1 DONE / bit2 ERROR / bit3 BUFFER_READY |
| `0x0024` | `ERR_CODE` | 1=维度为 0,2=tile 超出阵列,3=超 Buffer 容量,4=TK 非法 |
| `0x1000~0x10FF` | A Buffer | 64 字 |
| `0x2000~0x20FF` | BT Buffer | 64 字 |
| `0x3000~0x33FF` | C Buffer | 256 字 |

## 4. 数据布局约定(重要)

文档中 `a_in[P*8-1:0]`(每行/列每拍 1 个 INT8)要求每拍同时给 4 行 A 与 4 列 BT
各一个字节,因此 A/BT Buffer 采用 **k 主序、行进字节** 打包:

```text
A Buffer 第 (g*K + k) 个字:
  [7:0]   = A[g*TM + 0][k]
  [15:8]  = A[g*TM + 1][k]
  [23:16] = A[g*TM + 2][k]
  [31:24] = A[g*TM + 3][k]     (越界行填 0)
```

BT 同理(把"行"换成"列")。这样一拍弹出一个字即为阵列一拍的全部 4+4 路输入。
tile 基地址:`A 字基址 = tile_i*K + tile_k*TK`,`BT 字基址 = tile_j*K + tile_k*TK`,
`C 元素基址 = tile_i*TM*N + tile_j*TN`(行主序,C 字地址 = 基址 + r*N + c)。

## 5. 一个 K-tile 的时序

1. `PREFETCH_INPUT`:A/BT stream_ctrl 连续发 `valid_tk` 个同步 RAM 读,数据入两个预取 FIFO
2. `ARRAY_START`:PE 累加器清零、冲刷残留波前
3. `ARRAY_FEED`:`pair_stream_ctrl` 每拍弹出 A/BT 各一字,成对送入(任一侧无效即等待)
4. skew 管线:行 r 延迟 r 拍、列 c 延迟 c 拍 ⇒ A[r][k] 与 BT[c][k] 恰在 PE[r][c] 同拍相遇
5. `ARRAY_DRAIN`:继续推进 P+Q-2 = 6 个使能拍,波前走完最远端
6. 结果收集:16 拍串行输出 `c_result/c_scan_index/c_result_valid`，随后产生 `collect_done`，由 `c_tile_acc_ctrl` 装入或累加
7. 最后一个 K tile 完成后:量化(舍入右移 + 饱和)→ 逐项入 `c_write_fifo` → 写入 C RAM
8. `done_ctrl` 统计真正落 RAM 的写数,达到 M*N 且全部 tile 结束才发 `core_done`

## 6. 仿真结果(Icarus Verilog 13.0,10 ns 时钟)

```text
T1_单tile_4x4x4      PASS : M=4  N=4  K=4  TM=TN=4 TK=4 q=0 | C 写 16  项, 计算耗时 76   周期
T2_满规模_16x16x16   PASS : M=16 N=16 K=16 TM=TN=4 TK=4 q=0 | C 写 256 项, 计算耗时 3100 周期
T3_边界_6x7x9        PASS : M=6  N=7  K=9  TM=TN=4 TK=3 q=0 | C 写 42  项, 计算耗时 584  周期
T4_小tile_5x5x6      PASS : M=5  N=5  K=6  TM=2 TN=3 TK=3 q=0 | C 写 25 项, 计算耗时 624  周期
T5_量化_8x8x8_q2     PASS : M=8  N=8  K=8  TM=TN=4 TK=8 q=2 | C 写 64  项, 计算耗时 300  周期
T6_零维错误          PASS : DONE+ERROR, ERR_CODE=1
T7_超容量错误        PASS : DONE+ERROR, ERR_CODE=3
T8_TM为零错误        PASS : DONE+ERROR, ERR_CODE=2
T9_TN为零错误        PASS : DONE+ERROR, ERR_CODE=2
T10_TK为零错误       PASS : DONE+ERROR, ERR_CODE=4
==== 结果: PASS=10 FAIL=0 ====
```

覆盖:单 tile / 64 tile 多 K 累加 / M、N 非 tile 倍数的边界补零 / tile 步长小于阵列规模 /
负数舍入量化 / 尺寸、容量、TM、TN、TK 错误路径。数据为固定种子随机 INT8(含负数),期望值由测试台
按相同量化公式独立计算。

## 7. 复现

```powershell
# 依赖:Python3 + Icarus Verilog(如 C:\msys64\mingw64\bin\iverilog.exe)
python scripts/run_npu.py               # 编译 + 仿真,日志在 sim/logs/
python scripts/draw_arch.py             # 架构图,输出到 figures/
python scripts/draw_wavefront.py        # 脉动阵列波前图,输出到 figures/
python scripts/draw_wave.py             # T1 运行波形图(需先跑过仿真生成 sim/waves/npu_wave.vcd)
```

## 8. 实现过程中修复的典型问题(供报告参考)

1. **地址译码特征位错位**:0x1000/0x2000/0x3000 的区分位在 `addr[15:12]`,初版误用低位,
   导致 Buffer 读写目标错乱(读回的是状态寄存器值)。
2. **CPU 请求重复接收**:总线模型在 `cpu_ready` 后多保持一拍 `cpu_valid`,`mmio_if` 在 IDLE
   态会把它当新请求重复锁存,所有读结果错位一格。约定:**采样到 ready 的同一拍撤下 valid**。
3. **顶层写数据断线**:历史版本中 `cpu_port_ctrl` 的字节屏蔽写数据没有正确送到 Buffer RAM。
   当前版本由 `npu_top` 的组合输出桥接统一送出 `cpu_a_wdata/cpu_bt_wdata/cpu_c_wdata`，并由仿真覆盖。
4. **k-tile 间 feed_cnt 未清零**:NEXT_K 路径不经过 CLEAR_C_TILE,残留计数值使第二个及
   以后的 K tile 只喂 1 对数据就误判"喂数完成"。改为在 PREFETCH_INPUT 态重置。
5. **量化符号扩展**:32 位累加值赋给 64 位中间量时被零扩展,负数右移结果全错,
   显式 `$signed()` 修正。

## 9. 与设计文档的对应关系

- 文档中的模块和接线以当前 `rtl/` 文件为准；`npu_system.v` 与各子系统文件中均有对应端口连接。
- 文档中"TLA 握手、valid=1&&ready=0 保持"的原则体现为:FIFO 未满/非空才 push/pop、
  pair 两侧同时有效才同时弹出、写 FIFO 满则写回控制暂停。
- `core_done` 语义:最后一笔 C 数据**已写入 RAM**(c_wr_pulse 计数达到 M*N),而非仅进入 FIFO。
- `array_done` 语义:16 个结果**已全部送出并被累加器消费**。

## 10. 全部 RTL 模块清单

当前 `rtl/` 有 45 个 Verilog 文件：1 个系统顶层、44 个功能模块，以及公共宏定义头文件。下面按数据平面列出每个模块的责任。

### 10.1 系统与 CPU 控制平面

| 模块 | 文件 | 责任 |
|---|---|---|
| `npu_system` | `npu_system.v` | 连接四个平面，提供 CPU MMIO 顶层端口 |
| `npu_top` | `npu_top.v` | CPU 控制平面总封装 |
| `mmio_if` | `mmio_if.v` | 锁存请求、复用读响应、产生 `cpu_ready` |
| `addr_decoder` | `addr_decoder.v` | 控制/状态/A/BT/C 地址译码 |
| `control_regs` | `control_regs.v` | M/N/K、TM/TN/TK、qshift 和命令寄存器 |
| `status_regs` | `status_regs.v` | BUSY、DONE、ERROR、BUFFER_READY、ERR_CODE |
| `start_ctrl` | `start_ctrl.v` | 启动脉冲、参数锁存、任务完成状态 |
| `buffer_access_ctrl` | `buffer_access_ctrl.v` | CPU 与 NPU Buffer 端口仲裁 |

### 10.2 调度与 C 写回平面

| 模块 | 文件 | 责任 |
|---|---|---|
| `npu_ctrl` | `npu_ctrl.v` | 调度中心，连接全部控制子模块 |
| `tile_param_latch` | `tile_param_latch.v` | 启动时锁存任务参数 |
| `config_checker` | `config_checker.v` | 检查尺寸、Tile、TK 和容量 |
| `tile_scheduler` | `tile_scheduler.v` | 维护 `tile_i/tile_j/tile_k` |
| `loop_counters_tile_status` | `loop_counters_tile_status.v` | 首尾 Tile 和边界有效尺寸 |
| `block_addr_gen` | `block_addr_gen.v` | 生成 A、BT、C Tile 基地址 |
| `systolic_fsm` | `systolic_fsm.v` | 预取、喂数、排空、累加、写回状态机 |
| `a_stream_ctrl` | `a_stream_ctrl.v` | 发出 A RAM 读请求 |
| `bt_stream_ctrl` | `bt_stream_ctrl.v` | 发出 BT RAM 读请求 |
| `pair_stream_ctrl` | `pair_stream_ctrl.v` | A/BT FIFO 成对弹出 |
| `array_ctrl` | `array_ctrl.v` | 阵列 start/enable/clear/flush；`feed_last` 仅保留为兼容/波形信号 |
| `c_tile_acc_ctrl` | `c_tile_acc_ctrl.v` | 保存并累加一个 C Tile 的部分和 |
| `c_tile_write_ctrl` | `c_tile_write_ctrl.v` | 生成 C 地址、数据和写有效 |
| `done_ctrl` | `done_ctrl.v` | 统计真正落 RAM 的 C 写操作 |

### 10.3 Buffer 与搬运平面

| 模块 | 文件 | 责任 |
|---|---|---|
| `npu_buffer` | `npu_buffer.v` | A/BT/C RAM、FIFO 和状态的总封装 |
| `npu_read_port_ctrl` | `npu_read_port_ctrl.v` | 同步 RAM 返回到预取 FIFO |
| `cpu_port_ctrl` | `cpu_port_ctrl.v` | CPU 局部端口到 RAM 端口的转换 |
| `a_buffer` | `a_buffer.v` | 64x32 bit A RAM |
| `bt_buffer` | `bt_buffer.v` | 64x32 bit BT RAM |
| `c_buffer` | `c_buffer.v` | 256x32 bit C RAM |
| `a_prefetch_fifo` | `a_prefetch_fifo.v` | A 数据预取 FIFO |
| `bt_prefetch_fifo` | `bt_prefetch_fifo.v` | BT 数据预取 FIFO |
| `c_write_fifo` | `c_write_fifo.v` | C 写请求 FIFO |

### 10.4 MAC 与脉动阵列平面

| 模块 | 文件 | 责任 |
|---|---|---|
| `npu_mac` | `npu_mac.v` | MAC 平面总封装 |
| `a_input_unpacker` | `a_input_unpacker.v` | A 32 位字拆成 4 个 INT8 lane |
| `bt_input_unpacker` | `bt_input_unpacker.v` | BT 32 位字拆成 4 个 INT8 lane |
| `a_bt_skew_pipeline` | `a_bt_skew_pipeline.v` | 行/列波前延迟和 valid 对齐 |
| `pe_array` | `pe_array.v` | 4x4 PE 互连 |
| `pe_cell` | `pe_cell.v` | 有符号 INT8 乘加和数据转发 |
| `drain_controller` | `drain_controller.v` | 阵列排空计时 |
| `tile_result_collector` | `tile_result_collector.v` | 收集 16 个 PE 累加结果 |
| `output_reorder` | `output_reorder.v` | 物理扫描序转 C 行主序 |
| `result_quantizer` | `result_quantizer.v` | 舍入、右移和饱和 |
| `mac_status` | `mac_status.v` | 将 `collect_done` 转换为单拍 `array_done` |

### 10.5 通用基元

| 模块 | 文件 | 责任 |
|---|---|---|
| `npu_ram` | `npu_ram.v` | 参数化同步 RAM |
| `npu_sync_fifo` | `npu_sync_fifo.v` | 参数化同步 FIFO |
| `npu_stream_ctrl` | `npu_stream_ctrl.v` | 通用连续地址/长度控制 |
| `npu_defines` | `npu_defines.vh` | 宏、位宽、地址和错误码定义 |

## 11. 顶层端口与内部接口

### 11.1 `npu_system` CPU 端口

```text
clk, rst
cpu_addr[31:0], cpu_wdata[31:0], cpu_byte_en[3:0]
cpu_we, cpu_valid, cpu_rdata[31:0], cpu_ready
```

### 11.2 `npu_top <-> npu_ctrl`

```text
start_pulse
cfg_m/cfg_n/cfg_k[5:0]
cfg_tm/cfg_tn[2:0], cfg_tk[4:0], cfg_qshift[4:0]
core_busy, core_done, error_code[7:0]
```

`start_ctrl` 在 `start_pulse` 时锁存软件配置，运行期间软件继续写寄存器不会影响当前任务。

### 11.3 `npu_ctrl <-> npu_buffer`

```text
A/BT 读：a_addr[5:0], a_re, bt_addr[5:0], bt_re
A/BT FIFO：valid, rdata[31:0], count, pop
C 写回：cwr_valid, cwr_addr[7:0], cwr_data[31:0]
C FIFO：cwr_ready, cwr_empty, c_wr_pulse
```

### 11.4 `npu_ctrl <-> npu_mac`

```text
阵列控制：array_start, array_enable, array_clear_acc, array_flush
A/BT 流：a_stream_valid/data, bt_stream_valid/data, a_lane_en, bt_lane_en
阵列完成：array_done
C 结果：c_result_valid, c_result[31:0], c_result_index[3:0]
```

### 11.5 `npu_top <-> npu_buffer`

CPU 对三块 RAM 各有地址、读使能、写使能、写数据和读数据返回。`core_busy=1` 时 A/BT 读端口切换给 NPU，C 写端口切换给 C 写 FIFO；CPU 端口只保留状态允许的访问。

## 12. MMIO 地址和数据布局

| 地址 | 寄存器/存储 | 说明 |
|---|---|---|
| `0x0000_0000` | `CTRL` | bit0 start，bit1 clear_done |
| `0x0000_0004` | `M_CFG` | M，6 bit |
| `0x0000_0008` | `N_CFG` | N，6 bit |
| `0x0000_000C` | `K_CFG` | K，6 bit |
| `0x0000_0010` | `TM_CFG` | 1..4 |
| `0x0000_0014` | `TN_CFG` | 1..4 |
| `0x0000_0018` | `TK_CFG` | 1..16 |
| `0x0000_001C` | `QUANT_CFG` | 右移量 |
| `0x0000_0020` | `STATUS` | bit0 BUSY，bit1 DONE，bit2 ERROR，bit3 BUFFER_READY |
| `0x0000_0024` | `ERR_CODE` | 错误码 |
| `0x0000_1000..10FF` | A Buffer | 64 个 32 位字 |
| `0x0000_2000..20FF` | BT Buffer | 64 个 32 位字 |
| `0x0000_3000..33FF` | C Buffer | 256 个 32 位字 |

A/BT 一个 32 位字装四个连续行/列的 INT8。C 一个 32 位字保存一个结果元素。A/BT 使用 K 主序，C 使用行主序。

## 13. 一次任务的精确时序

```text
1. CPU 写 A/BT Buffer。
2. CPU 写 M/N/K、TM/TN/TK 和 qshift。
3. CPU 写 CTRL.start。
4. start_ctrl 锁存参数，产生 start_pulse。
5. config_checker 检查参数。
6. tile_scheduler 选择 tile_i/tile_j/tile_k。
7. block_addr_gen 计算 A/BT/C tile 地址。
8. a_stream_ctrl/bt_stream_ctrl 预取 valid_tk 个字。
9. RAM 返回数据进入 A/BT prefetch FIFO。
10. pair_stream_ctrl 成对弹出 A/BT。
11. unpacker 拆出 4+4 个 INT8，skew pipeline 注入波前。
12. PE 阵列执行乘加，A 向右、BT 向下传播。
13. array_flush 后等待 P+Q-2 及流水线附加周期。
14. collector/reorder 串行输出 16 个结果。
15. c_tile_acc_ctrl 沿 tile_k 累加。
16. 最后一个 K tile 经 result_quantizer 处理后进入 C 写 FIFO。
17. C 写 FIFO 将有效 C 元素写入 C Buffer。
18. 最后一笔写完成后 done_ctrl 产生 core_done。
19. CPU 读取 DONE 和 C Buffer，写 clear_done 回到 IDLE。
```

## 14. 握手和边界规则

- `valid=1 && ready=0` 时，数据和 valid 必须保持。
- A/BT 只有同时有效时才允许 pair pop。
- FIFO 满禁止 push，FIFO 空禁止 pop。
- `valid_tm/valid_tn` 控制边界行/列 lane，越界 lane 补零。
- `valid_tk` 控制 K tile 实际读取长度，越界 K 不访问 RAM。
- `c_tile_write_ctrl` 不为越界 C 元素产生写请求。
- `array_done` 表示结果流已消费完；`core_done` 表示最后一个 C 元素已经落入 RAM。

## 15. 验证覆盖

| 用例 | 覆盖点 | 结果 |
|---|---|---|
| 4x4x4 | 单 Tile 基本乘法 | PASS，76 周期 |
| 16x16x16 | 多输出 Tile、多个 K Tile 累加 | PASS，3100 周期 |
| 6x7x9 | M/N/K 非 Tile 整数倍、补零 | PASS，584 周期 |
| 5x5x6 | TM=2、TN=3 的非标准 Tile | PASS，624 周期 |
| 8x8x8 q2 | 负数、舍入、右移和饱和 | PASS，300 周期 |
| M=0 | 尺寸检查 | PASS，ERR_CODE=1 |
| Buffer 超容量 | 容量检查 | PASS，ERR_CODE=3 |

完整结果为 `PASS=10 FAIL=0`。测试台使用独立整数计算生成期望矩阵，不直接复用 RTL 内部结果。

## 16. 复现与输出文件

```bash
cd npu
python3 scripts/run_npu.py
```

输出位置：

```text
sim/build/tb_npu.vvp
sim/logs/compile.log
sim/logs/npu_sim.log
sim/waves/npu_wave.vcd
```

绘图：

```bash
python3 scripts/draw_arch.py
python3 scripts/draw_wavefront.py
python3 scripts/draw_wave.py
```

图片写入 `figures/`。`sim/build/`、`sim/logs/compile.log` 和 `sim/waves/npu_wave.vcd` 都可以删除后重新生成。

## 17. 已知集成边界

1. NPU 当前通过 `npu_system` 独立提供 MMIO，尚未接入 `project_risc_v` 的 AHB/APB 总线。
2. `rst` 为 NPU 独立高有效同步复位，已经与 `clk` 对齐；接入 SoC 时仍需明确复位同步关系。
3. 当前 `npu_mac` 的 `a_stream_ready/bt_stream_ready` 与 `array_enable` 同源；后续增加复杂反压时应将握手闭环化。
4. FPGA 实现前需要重新检查 RAM/FIFO 推断、PE 阵列时序、C 写 FIFO 反压和资源使用率。

## 18. 总结

```text
npu_top    = CPU/MMIO 控制平面
npu_ctrl   = Tile 调度、地址生成和时间控制平面
npu_buffer = A/BT/C 存储与搬运平面
npu_mac    = INT8 脉动阵列计算平面
```

四个平面共同完成配置、数据装载、Tile 遍历、FIFO 预取、波前注入、INT8 乘加、部分和累加、结果量化和 C Buffer 写回，形成完整的矩阵乘法硬件闭环。
