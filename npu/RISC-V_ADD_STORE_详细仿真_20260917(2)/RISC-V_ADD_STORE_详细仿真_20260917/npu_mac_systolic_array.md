# npu_mac：脉动阵列小模块与接线设计

## 1. 模块划分

`npu_mac` 建议拆分为：`array_top`、`a_input_unpacker`、`bt_input_unpacker`、`a_skew_pipeline`、`bt_skew_pipeline`、`pe_array`、`pe_cell`、`array_control`、`array_cycle_counter`、`drain_controller`、`tile_result_collector`、`output_reorder`、`result_quantizer`（可选）和 `mac_status`。

## 2. 总体接线

数据路径为：`A Buffer → A prefetch FIFO → a_input_unpacker → a_skew_pipeline → pe_array`；BT 路径为：`BT Buffer → BT prefetch FIFO → bt_input_unpacker → bt_skew_pipeline → pe_array`；结果路径为：`pe_array → tile_result_collector → output_reorder → npu_ctrl/C Buffer`。

`npu_ctrl` 将 `array_start、array_enable、array_clear_acc、array_flush、array_last` 送入 `array_control`，`array_control` 再向 PE 阵列输出 `pe_valid、pe_enable、pe_clear_acc`。阵列返回 `array_ready、array_busy、array_done、c_tile_result、c_tile_valid、c_tile_last`。

## 3. 顶层接口和位宽

采用 4×4 阵列、每个 Buffer 字为 32 位时：`clk/rst_n/array_start/enable/clear/flush` 均为 1 位；`a_stream_data` 和 `bt_stream_data` 为 32 位；`valid/ready/busy/done` 为 1 位。若每行或每列每拍输入一个 INT8，可定义 `a_in[P*8-1:0]` 和 `bt_in[Q*8-1:0]`，4×4 阵列时均为 32 位。PE 累加器建议至少 32 位。

## 4. 输入拆分

`a_input_unpacker` 将 `a_stream_data[31:0]` 拆为 `a0=data[7:0]`、`a1=data[15:8]`、`a2=data[23:16]`、`a3=data[31:24]`，并解释为有符号 INT8。`bt_input_unpacker` 对 `bt_stream_data[31:0]` 做同样处理。连接为：`buffer_access_ctrl → stream_data → unpacker`。

## 5. 波前延迟

`a_skew_pipeline` 为阵列不同输入行增加延迟：第 0 行延迟 0 拍，第 1 行延迟 1 拍，第 2 行延迟 2 拍，依次类推。`bt_skew_pipeline` 为不同输入列增加同样的列延迟。每级必须同时延迟 `data` 和 `valid`。

```text
a_row[0] → delay0 → PE[0][0]
a_row[1] → delay1 → PE[1][0]
bt_col[0] → delay0 → PE[0][0]
bt_col[1] → delay1 → PE[0][1]
```

## 6. `pe_cell` 单元

单个 PE 接收 `a_in[7:0]`、`bt_in[7:0]`、`psum_in[ACC_W-1:0]`、`valid_in`、`clear_acc` 和 `enable`，输出 `a_out[7:0]`、`bt_out[7:0]`、`psum_out` 和 `valid_out`。有效周期执行：`product = signed(a_in) × signed(bt_in)`，`psum_out = psum_in + product`，同时将 A 向右、BT 向下转发。

## 7. `pe_array` 接线

4×4 阵列的横向连接规则是 `PE[i][j].a_out → PE[i][j+1].a_in`；纵向连接规则是 `PE[i][j].bt_out → PE[i+1][j].bt_in`。左边界接收 A 波前，顶部边界接收 BT 波前，右边界和底部产生结果或继续转发。

```text
A0 → PE00 → PE01 → PE02 → PE03
A1 → PE10 → PE11 → PE12 → PE13
A2 → PE20 → PE21 → PE22 → PE23
A3 → PE30 → PE31 → PE32 → PE33
BT 从各列顶部向下传播
```

## 8. 阵列控制和排空

`array_control` 将 `array_start、array_enable、array_clear_acc、array_flush、array_last` 转换为 PE 控制信号。`array_cycle_counter` 在 enable 时计数，`drain_controller` 在输入结束后等待阵列排空，排空时间通常约为 `P+Q-2`，另加 PE 流水线延迟。状态为：`IDLE → FEED → RUN → DRAIN → RESULT → IDLE`。

## 9. 结果收集

`tile_result_collector` 收集阵列输出的部分和，产生 `c_tile_result`、`c_tile_valid` 和 `c_tile_last`。`output_reorder` 将 PE 输出顺序转换为 C Buffer 的行主序。若 tile 为 `TM×TN`，并行结果总线可定义为 `c_tile_result[TM*TN*ACC_W-1:0]`；串行写回时使用 `c_result[ACC_W-1:0]`、`c_result_index` 和 `c_result_valid`。

## 10. 与外部模块接线

与 `npu_ctrl`：`npu_ctrl → npu_mac` 传输 `array_start/enable/clear/flush/last` 和 A/BT 流；`npu_mac → npu_ctrl` 返回 `a_stream_ready、bt_stream_ready、array_ready、array_busy、array_done、c_tile_result、c_tile_valid、c_tile_last`。

与 `buffer_access_ctrl`：`buffer_access_ctrl → npu_mac` 传输 `a_stream_data[31:0]、a_stream_valid、bt_stream_data[31:0]、bt_stream_valid`；`npu_mac → buffer_access_ctrl` 传输 `c_addr[7:0]、c_wdata[31:0]、c_we`。

## 11. 一次 C tile 时序

1. `npu_ctrl` 发 `array_clear_acc`，清除 PE 累加器。
2. A/BT Buffer 将 tile 数据送入 FIFO。
3. unpacker 拆分 INT8，skew pipeline 加入波前延迟。
4. `array_enable` 置 1，PE 执行乘加并转发数据。
5. 最后一个 K 数据输入后，`array_flush` 置 1。
6. `drain_controller` 等待阵列排空。
7. `tile_result_collector` 收集 P×Q 个部分和。
8. 结果送入 C tile 累加器；最后一个 K tile 完成后写入 C Buffer。

## 12. 完整数据流

```text
npu_ctrl → array_control → pe_array
A Buffer → A FIFO → unpacker → skew → pe_array
BT Buffer → BT FIFO → unpacker → skew → pe_array
pe_array → result_collector → output_reorder → C Buffer
```

核心原则：`npu_ctrl` 决定 tile 和时间，`npu_mac` 负责输入对齐、PE 乘加、阵列排空和结果收集，`buffer_access_ctrl` 负责 Buffer 数据搬运。
