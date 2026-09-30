# NPU 波形调试指南（v2.1）

本文档说明如何通过 VCD 波形判断当前 NPU 是否正常工作，以及出现错误时应该按什么顺序定位。内容以当前 `rtl/`、`tb/tb_npu.v` 和 `scripts/run_npu.py` 的实际层次为准。

## 1. 生成和打开波形

先重新运行测试台，确保波形和当前 RTL 一致：

```bash
cd npu
python3 scripts/run_npu.py
```

只观察一次最简单的 `4x4x4` 单 Tile 运算时运行：

```bash
python3 scripts/run_npu.py --simple
```

该模式生成 `sim/waves/npu_wave_simple.vcd`，适合从 `start_pulse` 一直看到 `core_done`。
完整回归的波形是 `sim/waves/npu_wave.vcd`，用 GTKWave 打开：

```bash
gtkwave npu/sim/waves/npu_wave.vcd
```

当前回归共 19 项用例，第一次阅读建议从 G1 开始：

```text
G1：4x4x4 单输出 Tile、单 K Tile，最容易观察
G2：16x16x16，16 个输出 Tile × 4 个 K Tile（单任务最大规模）
G3/G4：M/N/K 非整除，边界补零
G5~G7：量化、K 非 TK 整数倍、多 K Tile + 量化
G8：TK=1，每个 K Tile 只有 1 拍
G9：同一 GEMM 换 TK，用于验证"TK 不影响结果"
GA：两段 K 累加，用于验证 accumulate
GB1~GB4：非法配置，观察 ERROR 而不是 BUSY
```

## 2. RTL 层次结构

VCD 的顶层实例为：

```text
tb_npu.dut
├── u_npu_top
├── u_tile_controller
├── u_npu_buffer
└── u_npu_mac
```

常用子层次：

```text
tb_npu.dut.u_npu_top.u_mmio_if
tb_npu.dut.u_npu_top.u_control_regs
tb_npu.dut.u_npu_top.u_start_ctrl
tb_npu.dut.u_tile_controller.u_systolic_fsm
tb_npu.dut.u_tile_controller.u_a_stream_ctrl
tb_npu.dut.u_tile_controller.u_bt_stream_ctrl
tb_npu.dut.u_tile_controller.u_c_tile_write_ctrl
tb_npu.dut.u_tile_controller.u_c_tile_write_ctrl.u_result_quantizer
tb_npu.dut.u_npu_buffer.u_a_buffer.mem
tb_npu.dut.u_npu_buffer.u_bt_buffer.mem
tb_npu.dut.u_npu_buffer.u_c_buffer.mem
tb_npu.dut.u_npu_buffer.u_a_prefetch_fifo.mem
tb_npu.dut.u_npu_buffer.u_bt_prefetch_fifo.mem
tb_npu.dut.u_npu_buffer.u_c_write_fifo.u_fifo
tb_npu.dut.u_npu_mac.u_skew
tb_npu.dut.u_npu_mac.u_pe_array.g_pe_row[1].g_pe_col[1].u_pe_cell   (PE[1][1])
tb_npu.dut.u_npu_mac.u_pe_array.g_pe_row[3].g_pe_col[3].u_pe_cell   (PE[3][3])
tb_npu.dut.u_npu_mac.u_drain_controller
```

与 v2.0 相比，以下层次**已经不存在**，看到旧文档里的路径不要再去找：

```text
u_npu_mac.u_a_input_unpacker / u_bt_input_unpacker   (拆包已合并进 npu_mac，看 a_lane[]/bt_lane[])
u_npu_mac.u_tile_result_collector                     (结果不再串行扫出)
u_tile_controller.u_c_tile_acc_ctrl                   (部分和回到 PE 内部)
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

### 3.2 任务控制与配置校验

```text
tb_npu.dut.start_pulse
tb_npu.dut.core_busy
tb_npu.dut.core_done
tb_npu.dut.cfg_m / cfg_n / cfg_k / cfg_tk / cfg_qshift / cfg_accumulate
tb_npu.dut.u_npu_top.u_start_ctrl.state      (ST_IDLE/ST_RUN/ST_DONE/ST_ERROR)
tb_npu.dut.u_npu_top.u_start_ctrl.cfg_ok
tb_npu.dut.u_npu_top.u_start_ctrl.error_status
tb_npu.dut.u_tile_controller.u_systolic_fsm.state
tb_npu.dut.u_tile_controller.tile_i / tile_j / tile_k
tb_npu.dut.u_tile_controller.valid_tm / valid_tn / valid_tk
```

### 3.3 A/BT 预取（与喂数重叠）

```text
tb_npu.dut.u_tile_controller.u_systolic_fsm.pf_start
tb_npu.dut.u_tile_controller.u_systolic_fsm.pf_next_start
tb_npu.dut.u_tile_controller.u_a_stream_ctrl.busy_out
tb_npu.dut.npu_a_addr / npu_a_re
tb_npu.dut.u_npu_buffer.a_ram_raddr / a_ram_re / a_ram_rdata
tb_npu.dut.u_npu_buffer.a_fifo_push
tb_npu.dut.a_fifo_count
tb_npu.dut.fifo_pair_pop
tb_npu.dut.npu_bt_addr / npu_bt_re
tb_npu.dut.u_npu_buffer.bt_ram_rdata
tb_npu.dut.bt_fifo_count
```

### 3.4 MAC 输入和阵列控制

```text
tb_npu.dut.stream_valid
tb_npu.dut.a_stream_data / bt_stream_data
tb_npu.dut.u_tile_controller.pair_fire
tb_npu.dut.acc_clear          (每个输出 Tile 一次，不能再出现在 K Tile 之间)
tb_npu.dut.array_enable
tb_npu.dut.drain_en
tb_npu.dut.drain_done
```

### 3.5 PE 和波前

`pe_array` 用 `generate` 例化，PE 实例名带生成块下标：

```text
tb_npu.dut.u_npu_mac.u_pe_array.g_pe_row[0].g_pe_col[0].u_pe_cell
tb_npu.dut.u_npu_mac.u_pe_array.g_pe_row[1].g_pe_col[1].u_pe_cell
tb_npu.dut.u_npu_mac.u_pe_array.g_pe_row[3].g_pe_col[3].u_pe_cell
```

每个 PE 观察：

```text
a_in  a_v_in  bt_in  bt_v_in  acc
```

同时观察拆包结果 `u_npu_mac.a_lane[0..3]` / `bt_lane[0..3]`、
skew 输出 `u_npu_mac.a_sk` / `bt_sk` 及 `a_sk_v` / `bt_sk_v`。

### 3.6 结果快照与写回

v2.1 不再有"串行扫出 16 拍"的阶段，排空完成的同一拍就整块快照：

```text
tb_npu.dut.drain_done
tb_npu.dut.u_tile_controller.u_c_tile_write_ctrl.snap_valid_in
tb_npu.dut.u_tile_controller.u_c_tile_write_ctrl.active_q
tb_npu.dut.u_tile_controller.u_c_tile_write_ctrl.idx_q        (0..15 扫描)
tb_npu.dut.u_tile_controller.u_c_tile_write_ctrl.snap_q       (结果快照)
tb_npu.dut.u_tile_controller.u_c_tile_write_ctrl.c_base_q     (快照对应的 C 基地址)
tb_npu.dut.u_tile_controller.u_c_tile_write_ctrl.cwr_valid_out
tb_npu.dut.u_tile_controller.u_c_tile_write_ctrl.idle_out
```

### 3.7 C 写回和完成

```text
tb_npu.dut.cwr_valid / cwr_addr / cwr_data
tb_npu.dut.cwr_ready / cwr_empty / c_wr_pulse
tb_npu.dut.u_npu_buffer.u_c_write_fifo.rmw_q     (累加模式的读-改-写相位)
tb_npu.dut.u_tile_controller.wr_cnt              (已真正落 RAM 的笔数)
tb_npu.dut.u_tile_controller.core_done
```

## 4. 正常任务的波形顺序（v2.1）

以 G1（4×4×4）为例，`u_systolic_fsm.state` 依次是：

```text
S_IDLE(0) -> S_INIT(1) -> S_CLEAR_ACC(2) -> S_PREFETCH(3) -> S_FEED(4)
          -> S_DRAIN(5) -> S_DONE(6) -> S_IDLE(0)
```

关键相位：

```text
S_CLEAR_ACC : acc_clear=1（冲掉上一次的累加值和残留波前），等 cwr_idle 后发 pf_start
S_PREFETCH  : array_enable=0，阵列整体冻结；FIFO count 涨到 valid_tk 后进入 FEED
S_FEED      : array_enable=1，pair_fire 每拍弹出一对 A/BT；
              同一拍 pf_next_start 启动下一个 K Tile 的预取（最后一个 K Tile 不发）
S_DRAIN     : array_enable=1、drain_en=1，保持 P+Q-2=6 拍；drain_done 后进入 S_DONE
S_DONE      : 等 core_done（wr_cnt 达到 M*N 且写回通路空闲）
```

**多 K Tile 的任务（G2/G7）波形要点**：

```text
S_FEED -> S_PREFETCH -> S_FEED -> ... （K/TK 次）
· 中途的 S_PREFETCH 只有 1~2 拍：预取已经与上一次 FEED 重叠完成
· 中途绝对不会出现 acc_clear=1 或 drain_en=1
· 也不会有 S_DRAIN：整个输出 Tile 只在最后一次 K Tile 之后排空一次
```

**多输出 Tile 的任务（G2）波形要点**：

```text
S_DRAIN -> S_CLEAR_ACC（此时 next_out_req=1、tile_j/tile_i 前进、tile_k 归零）
       -> 立刻进入下一个输出 Tile 的 S_PREFETCH/S_FEED
       -> 上一块的写回（cwr_valid/c_wr_pulse）与这一块的计算并行发生
```

## 5. MMIO 波形检查

一次寄存器访问应该看到：

```text
cpu_valid=1 -> (req_valid 单拍) -> cpu_ready=1 一个周期 -> 撤销 cpu_valid
```

排查要点：

- `cpu_ready` 只表示"本笔访问完成"，不是持续接收能力；CPU 端必须在采样到 ready 的同一拍
  撤销 `cpu_valid`，否则请求会被重复接收。
- 读 Buffer 比读寄存器多等一拍（`mmio_if` 的 `S_WAIT2` 等同步 RAM 读数据）。
- 未映射地址读回 0；`sel_status` 为 0 时不会返回状态寄存器内容。

## 6. 配置校验与 ERROR

写 `CTRL.start` 之后应该看到：

```text
合法配置：start_ctrl.state 由 ST_IDLE/ST_DONE 进入 ST_RUN，core_busy 拉高
非法配置：start_ctrl.state 进入 ST_ERROR，core_busy 保持 0，STATUS.ERROR=1
```

排查要点：

- `cfg_ok=0` 时不会产生 `start_pulse`，`u_systolic_fsm.state` 一直停在 S_IDLE；
- 逐步看 `cfg_ok` 的各个分量：`dim_ok`（M/N/K 非 0）、`tk_ok`（1..16）、
  `buf_ok`（`ceil(M/4)*K` 与 `ceil(N/4)*K` 不超过 64）、`cbuf_ok`（`M*N` 不超过 256）、
  `acc_ok`（accumulate=1 时 qshift 必须为 0）；
- 写 `CTRL.clear_done` 后 `error_status` 清零、状态回到 ST_IDLE。

## 7. Buffer 和 FIFO 的正常特征

- A/BT 预取 FIFO 深度 64；喂第 k 个 K Tile 时同时预取第 k+1 个，
  峰值占用是两段之和（2×TK ≤ 32），正常波形里不会接近 64。
- `fifo_pair_pop` 只在两个 count 都非零时出现。
- `c_write_fifo` 的 `push` 只受 `!full` 门控；`c_wr_pulse` 表示真正写入 C RAM，
  `tile_controller` 用它统计完成，不能统计入队数。
- 非累加模式每拍处理一项；`accumulate=1` 时 `rmw_q` 在 0/1 之间交替，每项占两拍。

## 8. 拆包与波前检查

- `u_npu_mac.a_lane[i]` 只在对应 `a_lane_en[i]=1` 时等于 `a_stream_data` 的字节，
  否则为 0（边界补零就在这里完成）。
- `u_npu_mac.a_sk` 的第 r 个字节应比 `a_lane[r]` 晚 r 拍；`bt_sk` 第 c 个字节晚 c 拍。
- 数据与 valid 必须一起延迟：如果 `a_sk` 移位了但 `a_sk_v` 没有同步移位，
  PE 会在错误周期累加。

## 9. PE 阵列检查

- `u_pe_cell.acc` 只在输出 Tile 开始（`acc_clear=1`）时清零；
  **K Tile 之间必须保持不变**——如果看到它在 K Tile 之间被清零，说明 `acc_clear`
  被错误地连到了每个 K Tile 的启动上（v2.0 的老问题）。
- `a_out`/`bt_out` 是 1 拍寄存转发，因此从阵列最左/最上输入到 PE[r][c] 的传播
  分别是 c 拍和 r 拍。
- 只有 `a_v_in && bt_v_in` 同时为 1 的那一拍，`acc` 才会加上乘积。

## 10. 排空和快照检查

```text
drain_controller.cnt_q      0 -> DRAIN_BEATS-1 = 5，共 6 拍
drain_controller.drain_done_out  在 drain_en 保持期间为电平（会多保持一拍）
```

排查要点：

- `drain_done` 是电平不是单拍脉冲；`c_tile_write_ctrl` 用 `snap_valid_in && !active_q`
  保证只捕获一次。如果看到快照被反复重载、`idx_q` 一直回到 0，检查这个门控。
- 快照必须连同 `c_base_q / valid_tm_q / valid_tn_q` 一起锁存。如果写回地址用的是
  实时的 `c_base`（而不是 `c_base_q`），多输出 Tile 任务会把整块结果写到下一块的地址上。

## 11. C 写回检查

- `idx_q` 从 0 走到 15 然后 `active_q` 回 0；边界 Tile 只是跳过无效 lane 的 `cwr_valid`，
  扫描长度不变。
- `wr_cnt` 应该稳步增加到 `M*N` 然后停止；`core_done` 在 `wr_cnt` 达到 `M*N`
  且 `cwr_idle=1` 之后一拍拉高。
- `accumulate=1` 时检查 `rmw_q`：先 `ram_re`（读原值），下一拍 `ram_we` 且
  `ram_wdata = ram_rdata + 入队值`。

## 12. 分模块定位故障

```text
没有 cpu_ready                 -> mmio_if
cpu_ready 有但寄存器不变        -> npu_top 内联译码 / control_regs.byte0_wr
start_pulse 不出现              -> start_ctrl 的 cfg_ok 与 state
start_pulse 有但状态机不动      -> systolic_fsm 的 start_pulse 连接
一直停在 S_PREFETCH             -> 预取突发或 FIFO count；看 stream_ctrl.busy_out
                               与 fifo count 是否达到 valid_tk
一直停在 S_FEED                 -> pair_fire 不成立：某个 FIFO 空
一直停在 S_DRAIN                -> drain_en/drain_done 或 drain_controller 计数
一直停在 S_DONE                 -> core_done 不成立：wr_cnt 没到 M*N 或 cwr_idle=0
卡在 S_CLEAR_ACC                -> cwr_idle=0：上一块的写回没排空
C 结果全为 0                    -> acc_clear 是否被永久拉高（累加器每拍清零）
C 结果写到了别的 tile 地址      -> 快照是否锁存了 c_base/valid_tm/valid_tn
K 方向结果少了/多了             -> K Tile 之间是否被清累加器或清 feed_cnt 位置不对
写回笔数不足                    -> c_wr_pulse 计数：写 FIFO 满或 RAM 端口被占用
```

## 13. 推荐的 GTKWave 波形组

```text
00_reset_mmio   : clk rst cpu_valid cpu_we cpu_addr cpu_wdata cpu_ready cpu_rdata
01_task_control : start_pulse core_busy core_done start_ctrl.state cfg_ok error_status
                  systolic_fsm.state tile_i tile_j tile_k valid_tm valid_tn valid_tk
02_prefetch     : pf_start pf_next_start stream_ctrl.busy_out npu_a_re a_ram_raddr
                  a_fifo_push a_fifo_count fifo_pair_pop bt_fifo_count
03_mac_input    : stream_valid a_stream_data bt_stream_data pair_fire
                  acc_clear array_enable drain_en drain_done
04_pe           : PE[0][0]/PE[1][1]/PE[3][3] 的 a_in a_v_in bt_in bt_v_in acc
05_result       : snap_valid_in active_q idx_q snap_q c_base_q cwr_valid cwr_ready
                  cwr_empty c_wr_pulse wr_cnt core_done
```

## 14. 阅读原则

1. **先看状态机再信号**：`u_systolic_fsm.state` 是 v2.1 里唯一的主时序，先确认它停在哪个状态，
   再判断那个状态该有哪些信号。
2. **区间看而非点看**：跨 K Tile 的连续性（`array_enable` 冻结、`acc` 保持）要看整段，
   单个时钟沿看不出来。
3. **并行看写回**：v2.1 的写回与下一个 Tile 的计算是并行的，`cwr_valid` 与
   `S_PREFETCH/S_FEED` 重叠是正常现象，不是 bug。
4. **先确认 BUSY**：`core_busy` 为 1 时 CPU 对 Buffer 的写会被丢弃但 `cpu_ready` 仍拉高，
   波形上表现为"写了却没生效"。先看 `core_busy` 再看数据。

## 15. 最小观察信号集合

只想快速判断一次任务是否正常，看这 8 个就够：

```text
tb_npu.dut.start_pulse
tb_npu.dut.u_tile_controller.u_systolic_fsm.state
tb_npu.dut.acc_clear
tb_npu.dut.valid_tk -> a_fifo_count / bt_fifo_count
tb_npu.dut.u_tile_controller.pair_fire
tb_npu.dut.drain_done
tb_npu.dut.u_tile_controller.wr_cnt
tb_npu.dut.core_done
```
