// npu_defines.vh — NPU 全局参数(所有模块共用)
//
// 约定：除 MMIO 对外地址外，NPU 内部 Buffer 地址均为 32 位字地址；
// 参数宏集中放在本文件，避免各模块重复写常量导致位宽和容量不一致。
`ifndef NPU_DEFINES_VH
`define NPU_DEFINES_VH

// 脉动阵列规模 P x Q；pe_array、lane_en 和排空计数均依赖这两个宏。
`define NPU_P 4
`define NPU_Q 4

// PE 累加器宽度(INT8 x INT8, K<=16 时最大 |acc| = 16*127*128 < 2^22, 取 32 位留量化余量)
`define NPU_ACC_W 32

// Buffer 容量：地址宽度 AW 对应 2^AW 个 32 位字。
`define NPU_ABUF_AW 6          // A Buffer  64 x 32bit = 256 个 INT8
`define NPU_BBUF_AW 6          // BT Buffer 64 x 32bit
`define NPU_CBUF_AW 8          // C Buffer  256 x 32bit, 一个字存一个 C 元素

// FIFO 深度(16 字)，TK 最大 16；NPU_FIFO_AW=5 还为 count 保留满/空区分位。
`define NPU_FIFO_AW 5

// 参数位宽
`define NPU_DIM_W 6            // M/N/K
`define NPU_TILE_W 3           // TM/TN (1..4)
`define NPU_TK_W 5             // TK (1..16)
`define NPU_QS_W 5             // 量化右移位数
`define NPU_TIDX_W 6           // tile 计数器位宽,支持 M/N=63 且 TM/TN=1
`define NPU_CBASE_W 9          // C 元素基地址中间位宽

// MMIO 地址映射(npu_top 内联译码使用)
`define NPU_ADDR_CTRL_BASE 32'h0000_0000  // 0x0000-0x001F 控制寄存器
`define NPU_ADDR_STAT_BASE 32'h0000_0020  // 0x0020-0x002F 状态寄存器
`define NPU_ADDR_ABUF_BASE 32'h0000_1000  // 0x1000-0x10FF A Buffer
`define NPU_ADDR_BBUF_BASE 32'h0000_2000  // 0x2000-0x20FF BT Buffer
`define NPU_ADDR_CBUF_BASE 32'h0000_3000  // 0x3000-0x33FF C Buffer

`endif
