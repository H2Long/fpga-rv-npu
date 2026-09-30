# NPU INT8 矩阵乘法加速器（v2.1）

本目录只保留 NPU RTL、测试台、设计文档、NPU 仿真波形和 NPU 架构图片。

## 目录

```text
npu/
├── rtl/                      NPU Verilog-2001 RTL，按功能平面分组（20 个 .v）
│   ├── common/               公共宏定义、RAM、FIFO 和读突发控制
│   ├── top/                  系统顶层、CPU/MMIO 控制和启动校验
│   ├── ctrl/                 Tile 调度、任务状态机和 C Tile 快照写回
│   ├── buffer/               A/BT/C Buffer、数据搬运和跨任务累加
│   └── mac/                  INT8 拆包、PE 阵列、波前对齐和排空计数
├── tb/tb_npu.v               NPU MMIO 行为测试台（19 项回归用例）
├── scripts/                  NPU 仿真和绘图脚本
├── docs/NPU_完整设计说明.md   当前 RTL 设计说明
├── docs/地址与寄存器表.md     MMIO 地址和全部寄存器定义
├── docs/版本更新说明.md       各版本模块、信号和数据流变化
├── docs/NPU波形调试指南.md     GTKWave 波形观察和故障定位指南
├── sim/logs/                 NPU 仿真日志
├── sim/waves/                NPU VCD 波形
├── figures/                  NPU 架构图、波前图和运行波形图
└── npu_architecture.drawio   NPU 架构图源文件
```

## 功能

- 4x4 INT8 输出驻留式脉动阵列，PE 累加器在 K Tile 之间连续累加
- A/BT/C 片上 Buffer 和预取/写回 FIFO，预取与喂数重叠
- M/N/K、TK、量化右移配置，TM=TN=4 固定
- Tile 调度、边界补零、结果快照与并行写回
- `ACC_CFG.accumulate` 跨任务累加，支持把 K 分段
- 启动前配置校验，非法配置置 `STATUS.ERROR` 而不是锁死
- MMIO 启动、状态查询和 C Buffer 读取

## 仿真

```bash
cd npu
python3 scripts/run_npu.py
# 只运行最简单的 4x4x4 单 Tile 仿真
python3 scripts/run_npu.py --simple
```

当前测试台覆盖单 Tile、最大规模多 Tile、多 K Tile、非整除边界、负数量化、
TK 不变性、跨任务累加和非法配置拒绝，共 19 项用例，预期结果为 `PASS=19 FAIL=0`。

`--simple` 模式只运行 G1 单 Tile，用于快速查看一次完整数据流；波形另存为 `sim/waves/npu_wave_simple.vcd`。

## 性能

16×16×16（单任务最大规模，A/BT 各用满 64 字）实测 956 周期、阵列利用率 26%；
8×8×32 为 336~360 周期、利用率 35%~38%。`TK` 取 2~16 的性能差别在 15% 以内。

## 绘图

```bash
python3 scripts/draw_arch.py
python3 scripts/draw_wavefront.py
python3 scripts/draw_wave.py
```

完整的模块清单、接口、地址映射、数据布局、时序、容量约束和验证说明见 [NPU_完整设计说明.md](docs/NPU_完整设计说明.md)；完整 MMIO 地址和寄存器定义见 [地址与寄存器表.md](docs/地址与寄存器表.md)；各版本变化见 [版本更新说明.md](docs/版本更新说明.md)；波形阅读方法见 [NPU波形调试指南.md](docs/NPU波形调试指南.md)。
