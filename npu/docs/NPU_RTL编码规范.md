# NPU RTL Verilog 编码规范

本文件是本项目 NPU RTL 的唯一编码规范，适用于 `rtl/` 下的 Verilog-2001 代码。内容整合了项目原有的 NPU RTL 约定和 `verilog项目规范(3).txt`；两者存在差异时，以本文件为准。

本规范的核心目标是统一接口声明、时序复位、组合逻辑、状态机、存储器和 FIFO 的写法，使 RTL 易读、易仿真、易综合和易维护。

## 1. 文件和模块

- 每个文件通常只实现一个主要模块，文件名应与模块名一致。
- 文件顶部先说明模块职责、数据布局、时序延迟、端口所有权和不能修改的接口假设，再写 `` `include `` 与模块声明。
- 按项目需要在文件顶部声明仿真时间单位：

  ```verilog
  `timescale 1ns / 1ps
  ```

- 统一使用 Verilog-2001 语法。示例中的省略号只表示省略实现，实际代码必须满足 Verilog 语法。
- 模块端口、参数和内部信号应分组排列，保持统一缩进和对齐。

## 2. 端口和信号

### 2.1 端口声明

- 输入端口直接使用 `input`，不额外写 `input wire`。
- 输出端口统一使用 `output reg`，以便在 `always` 块中赋值。
- 端口建议一行一个声明，位宽写在信号名前。

```verilog
module example (
    input              clk,
    input              rst,
    input       [1:0]  stage,
    input       [31:0] data_in,
    output reg  [31:0] data_out,
    output reg         valid_out
);
```

除非内部信号确实必须声明为 `wire`，否则内部组合信号声明为 `reg`，并在 `always @(*)` 中赋值。

### 2.2 命名约定

- 输入信号建议使用 `_in` 后缀，输出信号建议使用 `_out` 后缀。
- 多模块连续传输的同类信号使用 `_1`、`_2`、`_3` 等后缀表示级次。
- `*_valid` 表示当前拍数据或请求有效；`*_ready` 表示接收方当前拍可以接收；`fire` 或 `*_fire` 表示 `valid` 与 `ready` 同时成立并完成一次传输。
- `*_q` 表示寄存值，`*_d` 表示对应的下一状态或延迟值；`*_rdata` 表示读数据，必须说明它相对于读请求的返回周期。
- 信号名应准确表达功能，避免使用含义不明确的名称。

同一时钟域的 `valid`、`ready` 和 `data` 必须在模块注释中说明采样沿、保持周期和传输条件。

## 3. 参数、宏和状态

- 操作码、译码值、状态编码和其他重复使用的常量优先使用 `localparam` 或项目已有宏定义，避免在逻辑中散落裸二进制常量。
- 参数和宏使用大写或项目既有命名风格；状态常量建议使用 `S_`、`C_` 或 `ST_` 前缀。已有模块的稳定命名可以保持不变。
- 状态编码集中定义，在状态机中使用状态名而不是裸数值。

```verilog
localparam [6:0] OPCODE_OP     = 7'b0110011;
localparam [6:0] OPCODE_OP_IMM = 7'b0010011;

localparam [1:0]
    ST_IDLE  = 2'd0,
    ST_EXE   = 2'd1,
    ST_FLUSH = 2'd2,
    ST_STALL = 2'd3;
```

状态定义旁应说明每个状态的入口条件、保持条件和退出条件。

## 4. 时序逻辑

### 4.1 时钟和复位

所有时序逻辑统一使用：

```verilog
always @(posedge clk) begin
```

本项目的 `rst` 已经过硬件消抖并与 `clk` 对齐，使用高电平同步复位。因此：

- 复位必须在时序块内部用 `if (rst)` 判断。
- 不要在敏感列表中加入 `posedge rst` 或 `negedge rst`。
- 不要将本项目模块改写为异步低有效 `rst_n` 复位形式。
- 复位分支必须为所有相关状态寄存器、计数器和输出寄存器提供确定的初值。

```verilog
always @(posedge clk) begin
    if (rst) begin
        state_q <= ST_IDLE;
        count_q <= 32'd0;
    end
    else begin
        // 正常工作逻辑
    end
end
```

### 4.2 赋值和组织方式

- 时序逻辑使用非阻塞赋值 `<=`。
- 一个时序块通常依次写复位、单拍脉冲默认清零、状态或工作分支。
- 单拍脉冲在每个时钟沿默认清零，只在产生事件的分支拉高。
- 多个条件分支按优先级排列，通常为复位、主要工作状态、暂停/保持状态和默认行为。
- 状态机的状态转移、状态输出和计数器更新应位于同一时钟域。
- 同一时序块中同一信号的后续赋值会覆盖前面的赋值。使用这一行为时，必须让优先级清晰，避免无意的重复赋值。

```verilog
always @(posedge clk) begin
    if (rst) begin
        func10_dec <= 10'd0;
        func10_lsu <= 10'd0;
        r1         <= 5'd0;
    end
    else if (stage == ST_EXE) begin
        func10_dec <= 10'd0;
        func10_lsu <= 10'd0;

        case (inst_effective[6:0])
            OPCODE_OP: begin
                // OP 处理
            end
            OPCODE_OP_IMM: begin
                // OP-IMM 处理
            end
            default: begin
                // 未识别操作码的安全行为
            end
        endcase
    end
    else if (stage == ST_STALL) begin
        // 保持或暂停处理
    end
    else begin
        // 默认处理
    end
end
```

## 5. 组合逻辑

- 组合逻辑统一使用行为描述，写在 `always @(*)` 中。
- 组合逻辑使用阻塞赋值 `=`。
- 本项目组合判定不使用 `assign`；只有确实必须声明为 `wire` 的内部连线才允许采用工具要求的连线写法。
- 组合逻辑必须覆盖所有输入路径，避免综合出隐含锁存器。
- 推荐在逻辑入口先给输出和中间结果设置默认值，再在条件分支中覆盖。

```verilog
always @(*) begin
    br_en       = 1'b0;
    offset_beq1 = 32'd0;
    offset_beq2 = 32'd0;
    offset_jal1 = 32'd0;
    offset_jal2 = 32'd0;
    jal         = 1'b0;
    jalr        = 1'b0;

    if (!rst && branch_enable) begin
        br_en = 1'b1;
    end
end
```

## 6. `if`、`case` 和 `begin/end`

- 分支较多时优先使用 `case`，避免写成很长的连续 `else if`。
- `case` 建议始终包含 `default`，为未匹配输入规定明确行为。
- 分支只有一条语句时可以省略 `begin/end`；有多条语句时必须使用 `begin/end`。
- 状态机和指令译码优先使用已经定义的 `localparam` 状态名或操作码名。

```verilog
if (enable)
    data_out = data_in;
else
    data_out = 32'd0;
```

## 7. 握手接口和时序说明

- `valid` 与 `ready` 在同一时钟域内采样；只有两者在采样沿同时为高时，传输才算完成。
- 发送端在 `valid` 为高且尚未握手时，必须保持对应数据和控制信息稳定。
- 模块注释必须写明请求的采样沿、数据的保持周期和返回延迟。
- `fire` 信号只表示一次实际传输，不应把仅有 `valid` 或仅有 `ready` 当作传输完成。

## 8. RAM、Buffer 和 FIFO

### 8.1 RAM 和 Buffer

- 同步 RAM 必须说明请求沿与数据返回沿的关系。
- 读请求的 `valid` 与返回数据必须使用一致的延迟定义；若读数据一拍返回，应明确写出该一拍延迟。
- Buffer 地址必须说明单位，是字节地址、字地址还是其他粒度。
- MMIO 层负责地址到寄存器索引的转换，例如 32 位字寄存器可使用 `(addr - base) >> 2`。

### 8.2 FIFO

- `push` 必须受 `full` 门控，`pop` 必须受 `empty` 门控。
- 必须明确同时 `push` 和 `pop` 时计数器是增加、减少还是保持不变。
- FIFO 的数据有效性、读出延迟、满空边界和复位后的状态应写在模块注释中。

## 9. 注释要求

每个功能模块至少说明：

1. 模块在系统中的位置和职责；
2. 输入、输出数据的布局、位宽和单位；
3. `valid/ready` 或 RAM 的时序延迟；
4. 复位后的状态以及状态机的主要转移；
5. 边界条件、错误处理和不能修改的接口假设。

注释应解释“为什么这样写”，而不是重复代码字面含义。例如，必须说明为什么 `c_wr_pulse` 统计 C RAM 的实际写入，而不能统计 C 写 FIFO 的入队。

## 10. 推荐模块骨架

```verilog
`timescale 1ns / 1ps

module example (
    input              clk,
    input              rst,
    input       [1:0]  stage,
    input       [31:0] data_in,
    output reg  [31:0] data_out
);

    localparam [1:0]
        ST_IDLE = 2'd0,
        ST_EXE  = 2'd1;

    reg [31:0] data_d;

    always @(posedge clk) begin
        if (rst)
            data_out <= 32'd0;
        else if (stage == ST_EXE)
            data_out <= data_d;
        else
            data_out <= data_out;
    end

    always @(*) begin
        data_d = 32'd0;
        if (stage == ST_IDLE)
            data_d = data_in;
    end

endmodule
```

## 11. 提交前检查清单

- [ ] 文件和模块职责、接口所有权、数据布局及时序说明完整。
- [ ] 输入使用 `input`，输出使用 `output reg`，命名符合后缀和级次约定。
- [ ] 时序块只有 `always @(posedge clk)`，复位为块内高有效同步复位。
- [ ] 时序逻辑使用 `<=`，组合逻辑使用 `=`。
- [ ] 组合逻辑写在 `always @(*)` 中，所有输出路径均有赋值，无隐含锁存器。
- [ ] 状态和操作码使用 `localparam` 或项目宏，`case` 包含 `default`。
- [ ] valid/ready、RAM、FIFO 的采样和延迟关系已说明。
- [ ] RAM/FIFO 的地址单位、满空边界和同时读写行为已说明。
- [ ] 复位值、状态转移、边界条件和特殊设计原因已有注释。
