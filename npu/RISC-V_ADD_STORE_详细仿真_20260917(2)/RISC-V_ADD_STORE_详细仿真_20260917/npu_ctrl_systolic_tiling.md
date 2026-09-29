# npu_ctrl：分块与脉动阵列控制设计

本文定义采用分块和 P×Q 脉动阵列后的 npu_ctrl。控制单位由单个 C[i][j] 改为一个 C tile。

## 模块划分

模块包括：tile_scheduler、tile_param_latch、loop_counters、block_addr_gen、systolic_fsm、a_stream_ctrl、bt_stream_ctrl、array_ctrl、c_tile_acc_ctrl、c_tile_write_ctrl 和 done_ctrl。

## 接线关系

start_ctrl 将 start_pulse、M/N/K、TM/TN/TK 送入 npu_ctrl。tile_scheduler 输出 tile_i、tile_j、tile_k，连接 block_addr_gen 和 done_ctrl。block_addr_gen 输出 A、BT、C tile 基地址，分别连接 a_stream_ctrl、bt_stream_ctrl 和 c_tile_write_ctrl。systolic_fsm 连接 array_ctrl；array_ctrl 向 systolic_array 输出 array_start、array_enable、array_clear_acc、array_flush、array_valid、array_last，并接收 array_ready、array_done。

A 数据路径为：a_stream_ctrl → buffer_access_ctrl → A Buffer → a_prefetch_fifo → systolic_array 左侧。BT 数据路径为：bt_stream_ctrl → buffer_access_ctrl → BT Buffer → bt_prefetch_fifo → systolic_array 顶部。阵列结果路径为：systolic_array → c_tile_acc_ctrl → c_tile_write_ctrl → buffer_access_ctrl → C Buffer。

## 分块循环

计算循环为 tile_i、tile_j、tile_k 三层循环：外层遍历 C 的行块，中层遍历 C 的列块，内层遍历 K 方向块。还需要 cycle_cnt 记录阵列运行周期，drain_cnt 记录阵列排空周期。16×16×16 矩阵采用 4×4×4 分块时，三个 tile 计数器均为 2 位。

## 地址生成

行主序且 BT 已转置存储时：

```text
A_tile_base  = tile_i × TM × K + tile_k × TK
BT_tile_base = tile_j × TN × K + tile_k × TK
C_tile_base  = tile_i × TM × N + tile_j × TN
```

每个 32 位字含 4 个 INT8 时，RAM 字地址为元素地址右移 2 位。A、BT Buffer 地址宽度通常为 6 位，C Buffer 地址宽度通常为 8 位。

## 状态机

建议状态为：

```text
IDLE → LOAD_TILE_PARAM → CLEAR_C_TILE → LOAD_A_TILE
→ LOAD_BT_TILE → ARRAY_FEED → ARRAY_RUN → ARRAY_DRAIN
→ ACCUMULATE_TILE → WRITE_C_TILE → NEXT_TILE → DONE
```

ARRAY_FEED 负责按波前向阵列注入 A 和 BT；ARRAY_RUN 等待阵列计算；ARRAY_DRAIN 等待最后的部分和传播。排空周期通常约为 P+Q-2，另加 PE 内部流水线延迟。

## C tile 累加

当 tile_k 为 0 时，c_tile_acc_ctrl 清零 C tile 累加器；中间 K tile 只累加、不写回；最后一个 K tile 完成后，c_tile_write_ctrl 输出 c_addr[7:0]、c_wdata[31:0] 和 c_we 写入 C Buffer。

## Buffer 访问

buffer_access_ctrl 同时接收 CPU 端口和 NPU 端口。NPU 端口包括 a_addr_npu[5:0]、a_re_npu、bt_addr_npu[5:0]、bt_re_npu、c_addr_npu[7:0]、c_wdata_npu[31:0] 和 c_we_npu。RAM 侧 A/BT 数据宽度为 32 位，A/BT 地址为 6 位，C 地址为 8 位。

core_busy 为 0 时允许 CPU 访问 Buffer；core_busy 为 1 时 NPU 优先读取 A/BT 和写入 C，CPU 不允许修改 Buffer。建议增加 A prefetch FIFO、BT prefetch FIFO 和 C write FIFO，避免脉动阵列等待 RAM。

## 一次 C tile 时序

1. tile_scheduler 输出 tile_i、tile_j、tile_k。
2. block_addr_gen 生成 A、BT、C tile 基地址。
3. A/BT stream_ctrl 通过 buffer_access_ctrl 预取数据。
4. FIFO 向阵列左侧和顶部发送 A/BT 数据。
5. array_ctrl 拉高 array_enable，PE 执行乘加。
6. 输入结束后拉高 array_flush，等待阵列排空。
7. c_tile_acc_ctrl 接收当前 K tile 的部分结果。
8. 非最后 K tile 时 tile_k 加一并继续；最后 K tile 时写回 C tile。
9. 更新 tile_j、tile_i；最后一个 tile 完成后产生 core_done。

## 完整数据流

```text
start_ctrl → tile_scheduler → block_addr_gen
→ a_stream_ctrl/bt_stream_ctrl → buffer_access_ctrl
→ A/BT Buffer → prefetch FIFO → systolic_array
→ c_tile_acc_ctrl → c_tile_write_ctrl
→ buffer_access_ctrl → C Buffer → done_ctrl → status_regs
```
