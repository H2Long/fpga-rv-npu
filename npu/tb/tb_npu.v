// tb_npu — NPU 系统行为测试台（回归网）
//
// 通过 MMIO 装载 A/BT、配置参数、启动、轮询 DONE、读回 C 并与期望值比对。
//
// 覆盖点：
//   G1  4x4x4      单 Tile
//   G2  16x16x16   多输出 Tile + 多 K Tile（A/BT Buffer 满配置）
//   G3  6x7x9       M/N/K 非 Tile 整数倍（TM=TN=4, TK=3）
//   G4  5x5x6       M/N 边界 Tile
//   G5  8x8x8 q2    负数、舍入、右移、饱和
//   G6  8x8x10 TK=4 q3   K 不是 TK 整数倍 且 qshift>0（K 累加与量化组合）
//   G7  8x8x16 TK=4 q4   多个 K Tile 且 qshift>0
//   G8  8x8x7  TK=1      最小 K Tile（每个 K Tile 只有 1 拍）
//   G9  16x16x16 TK=1/4/8/16   同一 GEMM 换 TK，结果必须逐位一致
//   GA  8x8x16 拆成两段 K=8 累加    accumulate 位（跨任务累加）
//   GB  非法配置     超出 Buffer 容量的配置必须置 ERROR，不得进入 BUSY
//
// 数据布局（k 主序、行进字节）：A/BT Buffer 的第 (g*K + k) 个字，
// 字节 b = 矩阵第 g*4 + b 行(列)在第 k 步的 INT8 值。
`timescale 1ns/1ps

module tb_npu;

    localparam TM_TN = 4;              // 硬件固定 TM=TN=4

    // ---------------- 寄存器地址 ----------------
    localparam [31:0] A_CTRL   = 32'h0000_0000;   // bit0 start / bit1 clear_done
    localparam [31:0] A_M      = 32'h0000_0004;
    localparam [31:0] A_N      = 32'h0000_0008;
    localparam [31:0] A_K      = 32'h0000_000C;
    localparam [31:0] A_ACC    = 32'h0000_0010;   // bit0 accumulate
    localparam [31:0] A_TK     = 32'h0000_0018;
    localparam [31:0] A_QUANT  = 32'h0000_001C;
    localparam [31:0] A_STATUS = 32'h0000_0020;   // bit0 BUSY / bit1 DONE / bit3 RDY / bit4 ERROR
    localparam [31:0] A_BUF    = 32'h0000_1000;
    localparam [31:0] BT_BUF   = 32'h0000_2000;
    localparam [31:0] C_BUF    = 32'h0000_3000;

    localparam STATUS_BUSY  = 0;
    localparam STATUS_DONE  = 1;
    localparam STATUS_ERROR = 4;

    reg clk;
    reg rst;
    reg        cpu_valid;
    reg        cpu_we;
    reg [31:0] cpu_addr;
    reg [31:0] cpu_wdata;
    wire [31:0] cpu_rdata;
    wire        cpu_ready;

    integer cycle_cnt;

    npu_system dut(
        .clk(clk), .rst(rst),
        .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata), .cpu_byte_en(4'hF),
        .cpu_we(cpu_we), .cpu_valid(cpu_valid),
        .cpu_rdata(cpu_rdata), .cpu_ready(cpu_ready)
    );

    always #5 clk = ~clk;
    always @(posedge clk) cycle_cnt <= cycle_cnt + 1;

    initial begin
        $dumpfile("npu_wave.vcd");
        $dumpvars(0, tb_npu.dut);
    end

    // ---------------- 测试数据与统计 ----------------
    integer Am [0:63][0:63];   // A[M][K]
    integer Bt [0:63][0:63];   // BT[N][K]（B 的转置）
    integer Ex [0:63][0:63];   // 期望 C[M][N]

    integer num_pass, num_fail;
    integer i, j, kk, g, b;
    integer acc;
    reg signed [63:0] qt;
    reg [31:0] word, rdw, status;
    integer timeout, errs, t_start, t_end;

    integer m_r, n_r, k_r;

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        cpu_valid = 1'b0;
        cpu_we = 1'b0;
        cpu_addr = 32'd0;
        cpu_wdata = 32'd0;
        cycle_cnt = 0;
        num_pass = 0;
        num_fail = 0;
    end

    // ---------------- CPU 访问任务 ----------------
    // 采样到 cpu_ready 的同一拍立即撤下 cpu_valid，
    // 否则下一个时钟沿会被 mmio_if 当作新请求重复接收。
    task cpu_wr(input [31:0] a, input [31:0] d);
        begin
            @(negedge clk);
            cpu_valid = 1; cpu_we = 1; cpu_addr = a; cpu_wdata = d;
            while (!cpu_ready) @(negedge clk);
            cpu_valid = 0; cpu_we = 0;
        end
    endtask

    task cpu_rd(input [31:0] a, output [31:0] d);
        begin
            @(negedge clk);
            cpu_valid = 1; cpu_we = 0; cpu_addr = a;
            while (!cpu_ready) @(negedge clk);
            d = cpu_rdata;
            cpu_valid = 0;
        end
    endtask

    // ---------------- 数据生成与黄金模型 ----------------
    // 固定种子，数据落在 [-100, 100]，含负数。
    task gen_data(input integer m, input integer n, input integer k, input integer seed);
        begin
            for (i = 0; i < m; i = i + 1)
                for (kk = 0; kk < k; kk = kk + 1)
                    Am[i][kk] = ({$random(seed)} % 201) - 100;
            for (j = 0; j < n; j = j + 1)
                for (kk = 0; kk < k; kk = kk + 1)
                    Bt[j][kk] = ({$random(seed)} % 201) - 100;
        end
    endtask

    // 期望值：完整 K 维累加后按 qs 做四舍五入右移并饱和（与 RTL 的量化规则一致）。
    task calc_golden(input integer m, input integer n, input integer k, input integer qs);
        begin
            for (i = 0; i < m; i = i + 1)
                for (j = 0; j < n; j = j + 1) begin
                    acc = 0;
                    for (kk = 0; kk < k; kk = kk + 1)
                        acc = acc + Am[i][kk] * Bt[j][kk];
                    qt = acc;
                    if (qs != 0)
                        qt = (qt + (64'sd1 << (qs - 1))) >>> qs;
                    if      (qt >  64'sd2147483647) Ex[i][j] =  2147483647;
                    else if (qt < -64'sd2147483648) Ex[i][j] = -2147483648;
                    else                            Ex[i][j] = qt;
                end
        end
    endtask

    // ---------------- 装载 ----------------
    // 按"本段 K 长度"打包：第 (g*k_len + kk) 个字装第 g*4..g*4+3 行在第 (k_off+kk) 步的值。
    // k_off 是该段在完整 K 维上的起点，k_len 是本段长度（= 本次任务配置的 K）。
    task load_ab(input which, input integer k_off, input integer k_len);
        integer base, rows;
        begin
            if (which == 0) begin base = A_BUF;  rows = m_r; end
            else            begin base = BT_BUF; rows = n_r; end
            for (g = 0; g * TM_TN < rows; g = g + 1) begin
                for (kk = 0; kk < k_len; kk = kk + 1) begin
                    word = 32'd0;
                    for (b = 0; b < TM_TN; b = b + 1) begin
                        if (g * TM_TN + b < rows) begin
                            if (which == 0)
                                word[b*8 +: 8] = Am[g*TM_TN+b][k_off+kk];
                            else
                                word[b*8 +: 8] = Bt[g*TM_TN+b][k_off+kk];
                        end
                    end
                    cpu_wr(base + (g * k_len + kk) * 4, word);
                end
            end
        end
    endtask

    // ---------------- 启动与轮询 ----------------
    // 返回最终 STATUS；超时返回 0。
    task start_and_wait(output [31:0] st);
        begin
            t_start = cycle_cnt;
            cpu_wr(A_CTRL, 32'h1);
            timeout = 0;
            st = 32'd0;
            cpu_rd(A_STATUS, st);
            // 先等 BUSY 拉高（最多 20 拍），避免启动脉冲还没被接受就误判完成。
            while (!st[STATUS_BUSY] && !st[STATUS_ERROR] && timeout < 20) begin
                cpu_rd(A_STATUS, st);
                timeout = timeout + 1;
            end
            timeout = 0;
            while (!st[STATUS_DONE] && timeout < 200000) begin
                cpu_rd(A_STATUS, st);
                timeout = timeout + 1;
            end
            t_end = cycle_cnt;
        end
    endtask

    // ---------------- 读回比对 ----------------
    task check_c(input integer m, input integer n);
        begin
            errs = 0;
            for (i = 0; i < m; i = i + 1)
                for (j = 0; j < n; j = j + 1) begin
                    cpu_rd(C_BUF + (i * n + j) * 4, rdw);
                    if (rdw !== Ex[i][j][31:0]) begin
                        errs = errs + 1;
                        if (errs <= 3)
                            $display("    C[%0d][%0d] = %0d (0x%08h), 期望 %0d",
                                     i, j, $signed(rdw), rdw, Ex[i][j]);
                    end
                end
        end
    endtask

    // ---------------- 单任务 GEMM 测试 ----------------
    task run_gemm_test(input [255:0] name,
                       input integer m, n, k, tk, qs, seed);
        begin
            m_r = m; n_r = n; k_r = k;
            gen_data(m, n, k, seed);
            calc_golden(m, n, k, qs);

            cpu_wr(A_CTRL, 32'h2);                 // 清 DONE / ERROR
            load_ab(0, 0, k);
            load_ab(1, 0, k);
            cpu_wr(A_M, m); cpu_wr(A_N, n); cpu_wr(A_K, k);
            cpu_wr(A_TK, tk); cpu_wr(A_QUANT, qs); cpu_wr(A_ACC, 0);
            start_and_wait(status);

            if (status[STATUS_ERROR]) begin
                num_fail = num_fail + 1;
                $display("[%0s] FAIL : 合法配置被报 ERROR", name);
            end
            else if (!status[STATUS_DONE]) begin
                num_fail = num_fail + 1;
                $display("[%0s] FAIL : 超时未完成", name);
            end
            else begin
                check_c(m, n);
                if (errs == 0) begin
                    num_pass = num_pass + 1;
                    $display("[%0s] PASS : M=%0d N=%0d K=%0d TK=%0d q=%0d | C %0d 项, 耗时 %0d 周期",
                             name, m, n, k, tk, qs, m * n, t_end - t_start);
                end
                else begin
                    num_fail = num_fail + 1;
                    $display("[%0s] FAIL : %0d/%0d 处结果错误", name, errs, m * n);
                end
            end
        end
    endtask

    // ---------------- 跨任务累加测试 ----------------
    // 把 K=16 的 GEMM 拆成两段 K=8：第二段用 accumulate=1 保留累加器，
    // 最终 C 必须等于一次性做 K=16 的结果。
    task run_accum_test(input [255:0] name, input integer m, n, k_half, seed);
        begin
            m_r = m; n_r = n; k_r = k_half;
            gen_data(m, n, k_half * 2, seed);
            calc_golden(m, n, k_half * 2, 0);      // 期望：完整 K 累加，不量化

            // ---- 第一段 K ----
            cpu_wr(A_CTRL, 32'h2);
            load_ab(0, 0, k_half);
            load_ab(1, 0, k_half);
            cpu_wr(A_M, m); cpu_wr(A_N, n); cpu_wr(A_K, k_half);
            cpu_wr(A_TK, k_half); cpu_wr(A_QUANT, 0); cpu_wr(A_ACC, 0);
            start_and_wait(status);
            if (!status[STATUS_DONE]) begin
                num_fail = num_fail + 1;
                $display("[%0s] FAIL : 第一段未完成 STATUS=0x%08h", name, status);
            end
            else begin
                // ---- 第二段 K：accumulate=1 ----
                load_ab(0, k_half, k_half);
                load_ab(1, k_half, k_half);
                cpu_wr(A_M, m); cpu_wr(A_N, n); cpu_wr(A_K, k_half);
                cpu_wr(A_TK, k_half); cpu_wr(A_QUANT, 0); cpu_wr(A_ACC, 1);
                start_and_wait(status);
                if (!status[STATUS_DONE]) begin
                    num_fail = num_fail + 1;
                    $display("[%0s] FAIL : 第二段未完成 STATUS=0x%08h", name, status);
                end
                else begin
                    check_c(m, n);
                    if (errs == 0) begin
                        num_pass = num_pass + 1;
                        $display("[%0s] PASS : 两段 K=%0d 累加 == 单次 K=%0d", name, k_half, k_half * 2);
                    end
                    else begin
                        num_fail = num_fail + 1;
                        $display("[%0s] FAIL : %0d/%0d 处结果错误（跨任务累加未生效）",
                                 name, errs, m * n);
                    end
                end
            end
            cpu_wr(A_ACC, 0);
        end
    endtask

    // ---------------- 非法配置测试 ----------------
    // 配置超出 Buffer 容量时必须置 ERROR、不得进入 BUSY，并且 clear_done 之后可以恢复。
    task run_bad_config(input [255:0] name,
                        input integer m, n, k, tk);
        begin
            m_r = m; n_r = n;
            cpu_wr(A_CTRL, 32'h2);
            cpu_wr(A_M, m); cpu_wr(A_N, n); cpu_wr(A_K, k);
            cpu_wr(A_TK, tk); cpu_wr(A_QUANT, 0); cpu_wr(A_ACC, 0);
            cpu_wr(A_CTRL, 32'h1);
            repeat (10) @(negedge clk);
            cpu_rd(A_STATUS, status);
            if (!status[STATUS_ERROR] || status[STATUS_BUSY]) begin
                num_fail = num_fail + 1;
                $display("[%0s] FAIL : 非法配置 M=%0d N=%0d K=%0d TK=%0d 未报 ERROR (STATUS=0x%08h)",
                         name, m, n, k, tk, status);
            end
            else begin
                num_pass = num_pass + 1;
                $display("[%0s] PASS : 非法配置被拒绝 STATUS=0x%08h (ERROR=%b BUSY=%b)",
                         name, status, status[STATUS_ERROR], status[STATUS_BUSY]);
            end
            cpu_wr(A_CTRL, 32'h2);      // 清 ERROR，回到 IDLE
        end
    endtask

    // ---------------- 主流程 ----------------
    integer tk_scan;
    reg [31:0] st0, st1;

    initial begin
        repeat (5) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        if ($test$plusargs("ONLY_T1")) begin
            $display("==== NPU 简单单 Tile 仿真开始 ====");
            run_gemm_test("G1_单tile_4x4x4      ", 4, 4, 4, 4, 0, 32'h1);
        end
        else begin
            $display("==== NPU INT8 GEMM 回归开始 ====");
            run_gemm_test("G1_单tile_4x4x4      ", 4,  4,  4, 4, 0, 32'h1);
            run_gemm_test("G2_满规模_16x16x16   ", 16, 16, 16, 4, 0, 32'h2);
            run_gemm_test("G3_边界_6x7x9_TK3    ", 6,  7,  9, 3, 0, 32'h3);
            run_gemm_test("G4_边界_5x5x6_TK3    ", 5,  5,  6, 3, 0, 32'h4);
            run_gemm_test("G5_量化_8x8x8_q2     ", 8,  8,  8, 8, 2, 32'h5);
            run_gemm_test("G6_K10_TK4_q3        ", 8,  8, 10, 4, 3, 32'h6);
            run_gemm_test("G7_K16_TK4_q4        ", 8,  8, 16, 4, 4, 32'h7);
            run_gemm_test("G8_K7_TK1            ", 8,  7,  7, 1, 0, 32'h8);

            // G9：同一个 GEMM 换 TK 必须得到逐位相同的结果（验证累加器跨 K-tile 保留）
            $display("---- G9 TK 不变性（同一 GEMM，TK=1/2/4/8/16 结果必须一致）----");
            for (tk_scan = 1; tk_scan <= 16; tk_scan = tk_scan * 2)
                run_gemm_test("G9_TK不变性          ", 8, 8, 16, tk_scan, 0, 32'h9);

            // GA：跨任务累加
            run_accum_test("GA_跨任务累加_K8x2   ", 8, 8, 8, 32'hA);

            // GB：非法配置
            run_bad_config("GB1_超A容量          ", 63, 4, 63, 16);
            run_bad_config("GB2_超C容量          ", 32, 32, 1, 1);
            run_bad_config("GB3_TK超范围         ", 4, 4, 4, 31);
            run_bad_config("GB4_K为零            ", 4, 4, 0, 4);

            // 非法配置之后必须能正常恢复
            run_gemm_test("GC_非法配置后恢复    ", 4, 4, 4, 4, 0, 32'hB);
        end

        $display("==== 结果: PASS=%0d FAIL=%0d ====", num_pass, num_fail);
        if (num_fail == 0) $display("ALL TESTS PASSED");
        else               $display("SOME TESTS FAILED");
        $finish;
    end

    // 全局看门狗
    initial begin
        #50_000_000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end

endmodule
