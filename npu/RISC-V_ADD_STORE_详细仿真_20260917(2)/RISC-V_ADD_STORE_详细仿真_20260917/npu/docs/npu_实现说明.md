# NPU INT8 矩阵乘法加速器 — RTL 实现说明

本文档对应 `npu/` 目录下的完整 RTL 实现。设计依据为仓库根目录的
`npu_architecture_detailed_introduction.md`、`npu_top_interface_design.md`、
`npu_ctrl_systolic_tiling.md`、`npu_mac_systolic_array.md`、
`npu_four_module_interconnect.md` 五份设计文档,45 个功能模块与接线总表一一对应。

## 1. 功能

有符号 INT8 矩阵乘法:`C[M][N] = A[M][K] × BT[N][K]`(B 预先转置为 BT 存入)。

- 4×4 输出驻留式脉动阵列(P=Q=4),PE 累加器 32 位
- A/BT Buffer 64×32 bit,C Buffer 256×32 bit(一个 32 位字存一个 C 元素)
- 三层 tile 循环(tile_i/tile_j/tile_k),TM/TN ≤ 4,TK ≤ min(K, 32)
- 边界 tile 越界行/列在 unpacker 侧补零,越界 k 不读取,越界 C 项不写回
- K 方向部分和在 `c_tile_acc_ctrl` 中累加;最后经舍入/饱和量化写入 C Buffer
- CPU 通过 MMIO 配置、启动、查询状态、装载/读取 Buffer;运行期间(core_busy=1)CPU 端口被封锁

## 2. 目录结构

```text
npu/
├── rtl/                     46 个 Verilog-2001 文件(45 个功能模块 + npu_system 顶层)
│   ├── npu_defines.vh       全局参数(阵列规模/Buffer 容量/位宽/地址映射/错误码)
│   ├── npu_system.v        顶层:按接线总表连接四大子系统
│   ├── npu_top.v           CPU 控制平面(7 模块)
│   ├── npu_ctrl.v          调度中心(14 模块)
│   ├── npu_buffer.v        存储平面(8 模块)
│   ├── npu_mac.v           计算平面(8 模块)
│   └── …                    其余子模块每文件一个,与设计文档同名
├── tb/tb_npu.v              测试台(CPU 行为模型 + 7 项自校验测试)
├── scripts/                 仿真与绘图脚本
├── docs/                    设计说明
├── sim/                     编译产物、日志和波形
│   ├── build/tb_npu.vvp     可由脚本重建的仿真执行文件
│   ├── logs/                compile.log / npu_sim.log
│   └── waves/               npu_wave.vcd / npu_wave_reference.vcd
└── figures/                 三张 PNG + SVG
```

通用底层模块(被功能模块复用,不计入 45 个):`pe_cell`、`npu_ram`、`npu_sync_fifo`、`npu_stream_ctrl`。

## 3. MMIO 寄存器

| 地址 | 寄存器 | 说明 |
|---|---|---|
| `0x0000_0000` | `CTRL` | bit0=`start`,bit1=`clear_done` |
| `0x0000_0004` | `M_CFG` | M,6 位 |
| `0x0008` | `N_CFG` | N,6 位 |
| `0x000C` | `K_CFG` | K,6 位 |
| `0x0010` | `TM_CFG` | 行 tile 尺寸,1..4 |
| `0x0014` | `TN_CFG` | 列 tile 尺寸,1..4 |
| `0x0018` | `TK_CFG` | K 方向 tile 尺寸,1..min(K,32) |
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
6. 结果收集:16 拍串行输出 `acc[idx]/index/valid/last`,由 `c_tile_acc_ctrl` 装入或累加
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
==== 结果: PASS=7 FAIL=0 ====
```

覆盖:单 tile / 64 tile 多 K 累加 / M、N 非 tile 倍数的边界补零 / tile 步长小于阵列规模 /
负数舍入量化 / 两条错误路径。数据为固定种子随机 INT8(含负数),期望值由测试台
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
3. **顶层写数据断线**:`cpu_port_ctrl` 输出的(字节使能屏蔽后)写数据只连到内部线,
   未桥接到 `npu_top` 对外端口,RAM 收到高阻。补三根桥接赋值。
4. **k-tile 间 feed_cnt 未清零**:NEXT_K 路径不经过 CLEAR_C_TILE,残留计数值使第二个及
   以后的 K tile 只喂 1 对数据就误判"喂数完成"。改为在 PREFETCH_INPUT 态重置。
5. **量化符号扩展**:32 位累加值赋给 64 位中间量时被零扩展,负数右移结果全错,
   显式 `$signed()` 修正。

## 9. 与设计文档的对应关系

- 37 个功能方框全部落地且名称一致;`接线总表 §7.1-7.5` 的每条连线在
  `npu_system.v` / 各子系统文件中均有对应端口连接。
- 文档中"TLA 握手、valid=1&&ready=0 保持"的原则体现为:FIFO 未满/非空才 push/pop、
  pair 两侧同时有效才同时弹出、写 FIFO 满则写回控制暂停。
- `core_done` 语义:最后一笔 C 数据**已写入 RAM**(c_wr_pulse 计数达到 M*N),而非仅进入 FIFO。
- `array_done` 语义:16 个结果**已全部送出并被累加器消费**。
