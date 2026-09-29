# NPU INT8 矩阵乘法加速器

本目录只保留 NPU RTL、测试台、设计文档、NPU 仿真波形和 NPU 架构图片。

## 目录

```text
npu/
├── rtl/                      NPU Verilog RTL 和 npu_defines.vh
├── tb/tb_npu.v               NPU MMIO 行为测试台
├── scripts/                  NPU 仿真和绘图脚本
├── docs/NPU_完整设计说明.md   唯一的 NPU 设计说明
├── sim/logs/                 NPU 仿真日志
├── sim/waves/                NPU VCD 波形
├── figures/                  NPU 架构图、波前图和运行波形图
└── npu_architecture.drawio   NPU 架构图源文件
```

## 功能

- 4x4 INT8 输出驻留式脉动阵列
- A/BT/C 片上 Buffer 和预取/写回 FIFO
- M/N/K、TM/TN/TK、量化右移配置
- Tile 调度、边界补零、K 方向部分和累加
- MMIO 启动、状态查询、错误码和 C Buffer 读取

## 仿真

```bash
cd npu
python3 scripts/run_npu.py
```

当前测试台覆盖单 Tile、多 Tile、多 K Tile、非整除边界、小 Tile、负数量化以及两条错误路径，共 7 项测试，预期结果为 `PASS=7 FAIL=0`。

## 绘图

```bash
python3 scripts/draw_arch.py
python3 scripts/draw_wavefront.py
python3 scripts/draw_wave.py
```

完整的模块清单、接口、地址映射、数据布局、时序、错误处理和验证说明见 [NPU_完整设计说明.md](docs/NPU_完整设计说明.md)。
