# NPU INT8 矩阵乘法加速器 — RTL 实现说明（v2.1）

本文档对应 `npu/` 目录下的完整 RTL 实现，是当前 NPU 设计、接口、模块职责、时序和验证信息的唯一说明入口。内容以当前 `rtl/`、`tb/` 和 `scripts/` 为准。

## 1. 功能

有符号 INT8 矩阵乘法：`C[M][N] = A[M][K] × BT[N][K]`（B 预先转置为 BT 存入）。

- 4×4 输出驻留式脉动阵列（P=Q=4），PE 累加器 32 位
- A/BT Buffer 64×32 bit，C Buffer 256×32 bit（一个 32 位字存一个 C 元素）
- 三层 tile 循环（tile_i/tile_j/tile_k），TM=TN=4 固定，TK 可配 1..16
- 边界 tile 越界行/列补零，越界 k 不读取，越界 C 项不写回
- K 方向部分和**留在 PE 累加器里连续累加**：K Tile 之间不清累加器、不排空阵列
- 排空结束时把 16 个累加器整块锁存成快照，写回与下一个输出 Tile 的计算并行
- `ACC_CFG.accumulate=1` 时结果在 C Buffer 上累加，支持把 K 分段用多次任务累加
- 启动时校验配置（范围 + Buffer 容量），非法配置置 `STATUS.ERROR` 且不进入 BUSY
- CPU 通过 MMIO 配置、启动、查询状态、装载/读取 Buffer；运行期间（core_busy=1）CPU 端口被封锁

## 2. 目录结构

```text
npu/
├── rtl/                      Verilog-2001 文件，按功能平面分组（20 个 .v）
│   ├── common/               宏定义、RAM、FIFO、读突发控制
│   ├── top/                  系统顶层、CPU/MMIO 控制、启动校验
│   ├── ctrl/                 Tile 调度、任务状态机、C Tile 快照与写回
│   ├── buffer/               A/BT/C Buffer、数据搬运和跨任务累加
│   └── mac/                  INT8 拆包、波前对齐、PE 阵列、排空计数
├── tb/tb_npu.v               测试台（CPU 行为模型 + 19 项自校验回归）
├── scripts/                  仿真与绘图脚本
├── docs/                     设计说明
├── sim/                      编译产物、日志和波形
└── figures/                  架构图、波前图和运行波形图
```

## 3. MMIO 寄存器

| 地址 | 寄存器 | 说明 |
|---|---|---|
| `0x0000_0000` | `CTRL` | bit0=`start`，bit1=`clear_done`（命令寄存器，不保存）|
| `0x0000_0004` | `M_CFG` | M，6 位 |
| `0x0000_0008` | `N_CFG` | N，6 位 |
| `0x0000_000C` | `K_CFG` | K，6 位 |
| `0x0000_0010` | `ACC_CFG` | bit0 `accumulate`：跨任务累加到 C Buffer |
| `0x0000_0014` | 保留 | 读取为 0 |
| `0x0000_0018` | `TK_CFG` | K 方向 tile 尺寸，1..16 |
| `0x0000_001C` | `QUANT_CFG` | 结果右移位数（0=直通）|
| `0x0000_0020` | `STATUS` | bit0 BUSY / bit1 DONE / bit3 BUFFER_READY / bit4 ERROR |
| `0x0000_0024` | 保留 | 读取为 0 |
| `0x1000~0x10FF` | A Buffer | 64 字 |
| `0x2000~0x20FF` | BT Buffer | 64 字 |
| `0x3000~0x33FF` | C Buffer | 256 字 |

完整的寄存器位定义、容量约束和推荐软件顺序见 [地址与寄存器表.md](地址与寄存器表.md)。

## 4. 数据布局约定（重要）

文档中 `a_in[P*8-1:0]`（每行/列每拍 1 个 INT8）要求每拍同时给 4 行 A 与 4 列 BT
各一个字节，因此 A/BT Buffer 采用 **k 主序、行进字节** 打包：

```text
A Buffer 第 (g*K + k) 个字：
  [7:0]   = A[g*TM + 0][k]
  [15:8]  = A[g*TM + 1][k]
  [23:16] = A[g*TM + 2][k]
  [31:24] = A[g*TM + 3][k]     (越界行填 0)
```

BT 同理（把"行"换成"列"）。这样一拍弹出一个字即为阵列一拍的全部 4+4 路输入，
RAM 带宽（每拍 2 次读）与 16 个 PE 精确配平。

tile 基地址：`A 字基址 = tile_i*K + tile_k*TK`，`BT 字基址 = tile_j*K + tile_k*TK`，
`C 元素基址 = tile_i*TM*N + tile_j*TN`（行主序，C 字地址 = 基址 + r*N + c）。

## 5. 一个输出 Tile 的时序

```text
1. CLEAR_ACC   : 清 PE 累加器并冲刷残留波前，同时启动第一个 K Tile 的预取
                 （此状态还会等 cwr_idle，保证上一块的写回快照已被消费）
2. PREFETCH    : 等 A/BT FIFO 装满当前 K Tile。下一个 K Tile 的预取已经在
                 上一步的 FEED 期间启动，所以这里通常一拍通过
3. FEED        : 两侧 FIFO 都有数据时每拍成对弹出 A/BT，喂 valid_tk 拍；
                 进入 FEED 的同时启动下一个 K Tile 的预取（与喂数重叠）
4. K 循环      : 最后一个 K Tile 之前回到 PREFETCH，**不清累加器、不排空**；
                 阵列在 PREFETCH 期间整体冻结，整条 skew 管线一起保持偏移，
                 恢复后波前无缝续接 ⇒ 跨 K Tile 的部分和留在 PE 里连续累加
5. DRAIN       : 所有 K Tile 喂完后排空 P+Q-2 = 6 个使能拍，波前走完最远端
6. 结果快照    : 排空完成那一拍把 16 个累加器整块锁存进 c_tile_write_ctrl 的
                 影子寄存器（连同 C 基地址和边界尺寸一起锁存）
7. 写回        : 影子寄存器逐拍扫描 16 个 lane，量化后入 C 写 FIFO，
                 与下一个输出 Tile 的计算并行；accumulate=1 时做 C 读-改-写
8. 完成        : core_done 要求所有 tile 计算结束 **且** c_wr_pulse 计数达到
                 M*N **且** 写回通路空闲，即最后一笔 C 真正落入 RAM
```

同一个任务内的输出 Tile 顺序是行主序（tile_i 外层、tile_j 内层），
每个输出 Tile 结束时才排空一次，所以 K/TK 个 K Tile 只付一次排空开销。

## 6. 仿真性能（Icarus Verilog，10 ns 时钟）

驱动端到端测量（从写 `CTRL.start` 到 `STATUS.DONE` 拉高，含 CPU 轮询开销），
阵列利用率 = `M*N*K / (周期数 * 16)`：

| 用例 | 周期 | 阵列利用率 |
|---|---:|---:|
| 4×4×4，TK=4 | 48 | 8% |
| 16×16×16，TK=2 | 1116 | 22% |
| 16×16×16，TK=4 | 956 | 26% |
| 16×16×16，TK=16 | 1004 | 25% |
| 8×8×32，TK=4 | 360 | 35% |
| 8×8×32，TK=16 | 336 | 38% |

三点结论：

1. `TK` 现在只是流水长度参数：TK=2/4/16 的性能差别在 15% 以内
   （v2.0 中 TK=4 比 TK=16 慢 2.2 倍，因为每个 K Tile 都要排空一次）；
2. 16×16×16 是单个任务的最大规模（A/BT 各用满 64 字），从 v2.0 的 3031 拍降到 956 拍；
3. 剩余时间主要花在 CPU 的 MMIO 装载与 C 回读上——这部分只能靠 §16 的 DMA 解决。

## 7. 验证覆盖（回归网）

`tb/tb_npu.v` 共 19 项自校验用例，全部通过（`PASS=19 FAIL=0`）：

| 用例 | 覆盖点 |
|---|---|
| G1 4×4×4 | 单输出 Tile、单 K Tile |
| G2 16×16×16 TK=4 | 最大规模：16 个输出 Tile × 4 个 K Tile |
| G3 6×7×9 TK=3 | M/N/K 非 Tile 整数倍、边界补零 |
| G4 5×5×6 TK=3 | M/N 边界 Tile |
| G5 8×8×8 q=2 | 负数、舍入、右移、饱和 |
| G6 8×8×10 TK=4 q=3 | K 不是 TK 整数倍 **且** qshift>0 |
| G7 8×8×16 TK=4 q=4 | 多 K Tile 且 qshift>0 |
| G8 8×7×7 TK=1 | 最小 K Tile（每 K Tile 只有 1 拍） |
| G9 8×8×16 TK=1/2/4/8/16 | **TK 不变性**：同一 GEMM 换 TK 结果必须逐位一致 |
| GA 8×8×16 拆两段 K=8 | **跨任务累加** `ACC_CFG.accumulate` |
| GB1~GB4 | 非法配置（超 A 容量 / 超 C 容量 / TK 超范围 / K=0）必须置 ERROR 且不进入 BUSY |
| GC | 非法配置之后必须能正常恢复 |

数据为固定种子随机 INT8（含负数），期望值由测试台按同一量化公式独立计算。
`sim/logs/npu_sim.log` 是最近一次完整回归的日志。

## 8. 复现

```bash
cd npu
python3 scripts/run_npu.py               # 编译 + 完整回归，日志在 sim/logs/
python3 scripts/run_npu.py --simple      # 只运行 G1 4x4x4 单 Tile
python3 scripts/draw_arch.py             # 架构图，输出到 figures/
python3 scripts/draw_wavefront.py        # 脉动阵列波前图
python3 scripts/draw_wave.py             # G1 运行波形图（需先跑过仿真）
```

RTL 按 Verilog-2001（`iverilog -g2001`）编译，与 `scripts/run_npu.py` 的编译选项一致。

## 9. 实现过程中修复的典型问题（供报告参考）

**v2.0 阶段：**

1. **地址译码特征位错位**：0x1000/0x2000/0x3000 的区分位在 `addr[15:12]`，初版误用低位，
   导致 Buffer 读写目标错乱。
2. **CPU 请求重复接收**：总线模型在 `cpu_ready` 后多保持一拍 `cpu_valid`，`mmio_if` 在 IDLE
   态会重复锁存。约定：**采样到 ready 的同一拍撤下 valid**。
3. **级联适配层丢写数据**：历史版本中 CPU Buffer 写数据经过多层包装，出现字节屏蔽数据未送到
   RAM；当前由 `buffer_access_ctrl` 一次完成仲裁和字节屏蔽。
4. **K Tile 间 `feed_cnt` 未清零**：残留计数值使第二个及以后的 K Tile 只喂 1 对数据就误判完成。
5. **量化符号扩展**：32 位累加值赋给 64 位中间量时被零扩展，负数右移全错，显式 `$signed()` 修正。

**v2.1 阶段（本轮架构修改）：**

6. **`acc_clear` 忘记默认清零**：改成"每输出 Tile 清一次"后，它在 `case` 里只在
   `S_CLEAR_ACC` 赋值，没进默认清零列表，于是置位后永久保持，把累加器每拍清零，
   所有 C 结果恒为 0。凡是"电平型"状态机输出都必须在块首列进默认清零。
7. **`S_DRAIN` 结束漏发 `next_out_req`**：输出 Tile 永远不前进，16×16 的结果全部写进同一块，
   `wr_cnt` 无限增长。换 Tile 的请求必须在 `S_CLEAR_ACC` 之前一拍发出，否则
   `S_CLEAR_ACC` 里的 `pf_start` 会用到旧基地址。
8. **快照没锁存地址和边界尺寸**：状态机在排空完成同一拍就发 `next_out_req`，
   写回扫描期间 `c_base/valid_tm/valid_tn` 已经是"下一块"的值，整块结果写错地址。
   结论：快照必须把"结果 + 写回所需的全部上下文"一起锁存。
9. **跨任务累加不能放在 PE 累加器里**：16 个 PE 累加器被所有输出 Tile 复用，
   任务结束时保存的是**最后一块** Tile 的部分和，与下一任务的第一个输出 Tile 不对应。
   最终改为在 C 写回路径上做读-改-写（`c_write_fifo`），与 Tile 顺序无关。
10. **Verilog-2001 不允许实例输出直接驱动 reg**：编码规范要求端口统一用 `output reg`，
    因此状态机等子模块的输出必须先接到内部 `wire`，再在 `always @(*)` 里转发到端口。
    这正是各层"转发块"存在的原因，不是冗余包装。

## 10. 全部 RTL 模块清单（20 个 .v）

### 10.1 系统与 CPU 控制平面

| 模块 | 文件 | 责任 |
|---|---|---|
| `npu_system` | `top/npu_system.v` | 连接四个平面，提供 CPU MMIO 顶层端口 |
| `npu_top` | `top/npu_top.v` | MMIO 译码、状态读回、控制平面总封装 |
| `mmio_if` | `top/mmio_if.v` | 锁存请求、复用读响应、产生 `cpu_ready` |
| `control_regs` | `top/control_regs.v` | M/N/K、TK、qshift、accumulate 和命令寄存器 |
| `start_ctrl` | `top/start_ctrl.v` | 任务生命周期、启动前配置校验、参数锁存 |
| `buffer_access_ctrl` | `top/buffer_access_ctrl.v` | CPU/NPU 仲裁、字节屏蔽和 RAM 端口 |

### 10.2 调度与 C 写回平面

| 模块 | 文件 | 责任 |
|---|---|---|
| `tile_controller` | `ctrl/tile_controller.v` | Tile 循环、地址生成、预取/喂数时序、完成计数 |
| `systolic_fsm` | `ctrl/systolic_fsm.v` | 7 状态任务机：清累加器、预取、喂数、排空、完成 |
| `c_tile_write_ctrl` | `ctrl/c_tile_write_ctrl.v` | 结果快照、边界过滤、扫描写回（内含 `result_quantizer`）|

### 10.3 Buffer 与搬运平面

| 模块 | 文件 | 责任 |
|---|---|---|
| `npu_buffer` | `buffer/npu_buffer.v` | A/BT/C RAM、FIFO 和端口归属的总封装 |
| `c_write_fifo` | `buffer/c_write_fifo.v` | C 写请求 FIFO；`accumulate=1` 时做 C 读-改-写 |
| `npu_ram` | `common/npu_ram.v` | 参数化同步 RAM |
| `npu_sync_fifo` | `common/npu_sync_fifo.v` | 参数化 FWFT 同步 FIFO |
| `npu_stream_ctrl` | `common/npu_stream_ctrl.v` | 单拍启动、自动结束的连续地址读突发 |

### 10.4 MAC 与脉动阵列平面

| 模块 | 文件 | 责任 |
|---|---|---|
| `npu_mac` | `mac/npu_mac.v` | 拆包、波前对齐、PE 阵列和排空计数的总封装 |
| `a_bt_skew_pipeline` | `mac/a_bt_skew_pipeline.v` | 行 r / 列 c 延迟 r/c 拍，数据与 valid 同步 |
| `pe_array` | `mac/pe_array.v` | `generate` 例化 P×Q 个 PE 的转发网络 |
| `pe_cell` | `mac/pe_cell.v` | 有符号 INT8 乘加和数据转发 |
| `drain_controller` | `mac/drain_controller.v` | 阵列排空计时（P+Q-2 拍） |
| `result_quantizer` | `mac/result_quantizer.v` | 舍入右移和饱和 |

## 11. 顶层端口与内部接口

### 11.1 `npu_system` CPU 端口

```text
clk, rst
cpu_addr[31:0], cpu_wdata[31:0], cpu_byte_en[3:0]
cpu_we, cpu_valid, cpu_rdata[31:0], cpu_ready
```

### 11.2 `npu_top <-> tile_controller`

```text
start_pulse
cfg_m/cfg_n/cfg_k[5:0]
cfg_tk[4:0], cfg_qshift[4:0]
core_busy, core_done
```

`start_ctrl` 在 `start_pulse` 时锁存软件配置，运行期间软件继续写寄存器不会影响当前任务。
`cfg_accumulate` 直接送到 `npu_buffer`（累加发生在 C 写回路径）。

### 11.3 `tile_controller <-> npu_buffer`

```text
A/BT 读：a_addr[5:0], a_re, bt_addr[5:0], bt_re
A/BT FIFO：rdata[31:0], count, pair_pop
C 写回：cwr_valid, cwr_addr[7:0], cwr_data[31:0]
C FIFO：cwr_ready, cwr_empty, c_wr_pulse
```

### 11.4 `tile_controller <-> npu_mac`

```text
阵列控制：acc_clear, array_enable, drain_en
A/BT 流：stream_valid, a_stream_data, bt_stream_data, a_lane_en, bt_lane_en
阵列状态：drain_done
阵列结果：acc_flat[16*32-1:0]（PE[r][c] 在第 (r*4+c)*32 位）
```

### 11.5 `npu_top <-> npu_buffer`

CPU 对三块 RAM 各有地址、读使能、写使能、写数据和读数据返回。`core_busy=1` 时
A/BT 读端口切换给 NPU，C 写端口切换给 C 写 FIFO，C 读端口也切换给 C 写 FIFO
（跨任务累加要读原值）；CPU 端口只保留状态允许的访问。

## 12. MMIO 地址和数据布局

见 §3 与 [地址与寄存器表.md](地址与寄存器表.md)。A/BT 一个 32 位字装四个连续行/列的 INT8，
C 一个 32 位字保存一个结果元素；A/BT 使用 K 主序，C 使用行主序。

## 13. 一次任务的精确时序

```text
1.  CPU 写 A/BT Buffer（BUSY 必须为 0）
2.  CPU 写 M/N/K、TK、qshift、accumulate
3.  CPU 写 CTRL.start
4.  start_ctrl 校验配置；非法则置 ERROR 并停在 ERROR 状态，合法则锁存参数并产生 start_pulse
5.  systolic_fsm 从 S_IDLE 进入 S_INIT，复位三层 Tile 计数器
6.  S_CLEAR_ACC：清 PE 累加器（冲刷波前），等 cwr_idle 后启动第一个 K Tile 的预取
7.  两个 npu_stream_ctrl 各自发出 valid_tk 个读请求，数据进入 A/BT 预取 FIFO
8.  S_FEED：每拍成对弹出 A/BT，拆包后经 skew 管线注入阵列；
    进入 FEED 的同时启动下一个 K Tile 的预取
9.  下一个 K Tile 之前不排空、不清累加器，阵列在 S_PREFETCH 期间整体冻结 ⇒ 无缝续算
10. 所有 K Tile 结束后 S_DRAIN：保持阵列推进 P+Q-2 = 6 个使能拍
11. 排空完成那一拍把 16 个累加器连同 C 基地址、边界尺寸锁存成快照
12. 快照扫描 16 个 lane：量化 → 入 C 写 FIFO → 写入 C RAM（accumulate=1 时先读原值相加）
13. 下一个输出 Tile 立刻开始计算，写回在后台进行
14. 最后一笔 C 写完成后 core_done 拉高，start_ctrl 进入 ST_DONE
15. CPU 读 DONE 和 C Buffer
```

## 14. 握手和边界规则

- A/BT FIFO count 同时非零时才允许 pair pop。
- FIFO 满禁止 push，FIFO 空禁止 pop；两条流共用同一 `stream_valid`，因此喂数期间
  两侧插入的等待空隙完全一致，不会破坏波前配对。
- `valid_tm/valid_tn` 控制边界行/列 lane，越界 lane 补零。
- `valid_tk` 控制 K Tile 实际读取长度，越界 K 不访问 RAM。
- `c_tile_write_ctrl` 不为越界 C 元素产生写请求。
- `drain_done` 表示波前已走完最远端；`core_done` 表示最后一个 C 元素已经落入 RAM。
- 预取 FIFO 深度 64，峰值占用为两个 K Tile（2×16）共 32 字，留一倍余量。

## 15. v2.1 相对 v2.0 的架构变化

| 变化 | 说明 | 效果 |
|---|---|---|
| K Tile 间不再清累加器、不再排空 | 部分和留在 PE 中连续累加，阵列在预取期间整体冻结保波前 | 16×16×16 从 3031 拍到 956 拍；TK 从"性能陷阱"变成普通参数 |
| 删除 `c_tile_acc_ctrl` 与 `tile_result_collector` | 结果不再串行扫出再在阵列外累加，改为快照 + 直接写回 | 每输出 Tile 少 16 拍，少 2 个模块、约 1000 个触发器，结果通路从穿 6 个模块降到 2 个 |
| 预取与喂数重叠 | `npu_stream_ctrl` 改为单拍启动、自动结束的突发；FIFO 深度 64 | 预取延迟被喂数覆盖 |
| 结果快照 + 后台写回 | 写回不再占用状态机状态 | 写回与下一个 Tile 的计算并行 |
| 启动前配置校验 | `start_ctrl` 校验范围与 Buffer 容量，非法置 `STATUS.ERROR` | 旧版写 TK=0 / K=0 / 超容量配置会把 BUSY 永久卡死，只能硬件复位 |
| `DONE=1` 时接受新的 `start` | 新任务直接启动并清 DONE | 旧版会静默丢弃 start，软件会一直读到上一次的旧结果 |
| `ACC_CFG.accumulate` | 在 C 写回路径做读-改-写 | 支持把 K 分段、多次任务累加出完整部分和 |
| `pe_array`/`drain_controller` 真参数化 | `generate` 例化，排空拍数由 `NPU_P+NPU_Q-2` 推出 | 删掉 16 段手写例化，P/Q 宏不再是装饰 |
| `input_unpacker` 合并进 `npu_mac` | 只被 MAC 平面使用的纯组合拆包 | 少一个模块和 8 个端口 |
| 未映射地址读回 0 | `mmio_if` 按 `sel_status` 判定，保留地址返回 0 | 修复"任意地址都返回状态寄存器" |

RTL 规模：20 个 `.v` + 1 个 `.vh`，约 2080 行（v2.0 为 28 个模块、2089 行，但删掉了两个
完整数据通路模块并简化了状态机）。

## 16. 已知集成边界

1. NPU 当前通过 `npu_system` 独立提供 MMIO，尚未接入 `project_risc_v` 的 AHB/APB 总线。
2. `rst` 为 NPU 独立高有效同步复位，已经与 `clk` 对齐；接入 SoC 时仍需明确复位同步关系。
3. 单任务最大规模受片上 Buffer 限制（`M*N<=256` 且 `ceil(M/4)*K<=64`），
   更大的层需要由软件分块并配合 `accumulate` 使用。
4. **没有 DMA/主端口**：A/BT 必须由 CPU 用 MMIO 逐字装载，C 也必须逐字读回。
   实测这部分占端到端时间的一半以上，是当前最大的性能瓶颈；下一步应加描述符驱动的
   DMA 读端口和中断，而不是继续优化阵列内部。
5. FPGA 实现前需要重新检查 RAM/FIFO 推断、PE 阵列时序、C 写 FIFO 反压和资源使用率。
