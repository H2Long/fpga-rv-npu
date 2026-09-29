// tb_npu — NPU 系统测试台
// 通过 MMIO 装载 A/BT、配置参数、启动、轮询 DONE、读回 C 并与期望值比对。
//
// 测试覆盖:
//  T1  4x4x4    TM=TN=4 TK=4   单 tile
//  T2  16x16x16 TM=TN=4 TK=4   4x4x4 = 64 个 tile, 多 K tile 累加(Buffer 满配置)
//  T3  6x7x9    TM=TN=4 TK=3   边界补零(M/N 非 tile 尺寸倍数)
//  T4  5x5x6    TM=2 TN=3 TK=3 tile 步长 != 阵列规模
//  T5  8x8x8    TM=TN=4 TK=8 qshift=2  量化舍入(含负数)
//  T6  M=0 配置错误 -> ERROR=1, ERR_CODE=1
//  T7  Buffer 超容量 -> ERR_CODE=3
//
// 数据布局(k 主序、行进字节):A/BT Buffer 的第 (g*K + k) 个字,
// 字节 b = 矩阵第 g*TM/TN + b 行(列)在第 k 步的 INT8 值。
`timescale 1ns/1ps

module tb_npu;

    reg clk;
    reg rst_n;
    reg        cpu_valid;
    reg        cpu_we;
    reg [31:0] cpu_addr;
    reg [31:0] cpu_wdata;
    wire [31:0] cpu_rdata;
    wire        cpu_ready;

    integer cycle_cnt;
    integer t_start, t_end;

    npu_system dut(
        .clk(clk), .rst_n(rst_n),
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

    // ---------------- 寄存器地址 ----------------
    localparam [31:0] A_CTRL   = 32'h0000_0000;
    localparam [31:0] A_M      = 32'h0000_0004;
    localparam [31:0] A_N      = 32'h0000_0008;
    localparam [31:0] A_K      = 32'h0000_000C;
    localparam [31:0] A_TM     = 32'h0000_0010;
    localparam [31:0] A_TN     = 32'h0000_0014;
    localparam [31:0] A_TK     = 32'h0000_0018;
    localparam [31:0] A_QUANT  = 32'h0000_001C;
    localparam [31:0] A_STATUS = 32'h0000_0020;
    localparam [31:0] A_ERR    = 32'h0000_0024;
    localparam [31:0] A_BUF    = 32'h0000_1000;
    localparam [31:0] BT_BUF   = 32'h0000_2000;
    localparam [31:0] C_BUF    = 32'h0000_3000;

    // ---------------- 测试数据与参数 ----------------
    integer Am [0:63][0:63];   // A[M][K]
    integer Bt [0:63][0:63];   // BT[N][K](B 的转置)
    integer Ex [0:63][0:63];   // 期望 C[M][N]

    integer num_pass, num_fail;
    integer i, j, kk, g, b;
    integer acc;
    reg signed [63:0] qt;
    reg [31:0] word, rdw, status;
    integer timeout;
    integer errs;

    integer m_r, n_r, k_r, tm_r, tn_r, tk_r, qs_r;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        cpu_valid = 1'b0;
        cpu_we = 1'b0;
        cpu_addr = 32'd0;
        cpu_wdata = 32'd0;
    end

    // ---------------- CPU 访问任务 ----------------
    // 采样到 cpu_ready 的同一拍立即撤下 cpu_valid,
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

    // 装载一个矩阵到 Buffer(k 主序、行进字节打包)
    task load_ab(input which);   // 0=A 1=BT
        integer base, stride_t, rows;
        begin
            if (which == 0) begin base = A_BUF; stride_t = tm_r; rows = m_r; end
            else            begin base = BT_BUF; stride_t = tn_r; rows = n_r; end
            for (g = 0; g * stride_t < rows; g = g + 1) begin
                for (kk = 0; kk < k_r; kk = kk + 1) begin
                    word = 32'd0;
                    for (b = 0; b < 4; b = b + 1) begin
                        if (g * stride_t + b < rows) begin
                            if (which == 0)
                                word[b*8 +: 8] = Am[g*stride_t+b][kk];
                            else
                                word[b*8 +: 8] = Bt[g*stride_t+b][kk];
                        end
                    end
                    cpu_wr(base + (g * k_r + kk) * 4, word);
                end
            end
        end
    endtask

    // ---------------- 完整功能测试 ----------------
    task run_gemm_test(input [127:0] name, input integer m, n, k, tm, tn, tk, qs, seed);
        begin
            m_r = m; n_r = n; k_r = k; tm_r = tm; tn_r = tn; tk_r = tk; qs_r = qs;

            // 生成数据(固定种子, [-100, 100], 含负数)
            for (i = 0; i < m; i = i + 1)
                for (kk = 0; kk < k; kk = kk + 1)
                    Am[i][kk] = ({$random(seed)} % 201) - 100;
            for (j = 0; j < n; j = j + 1)
                for (kk = 0; kk < k; kk = kk + 1)
                    Bt[j][kk] = ({$random(seed)} % 201) - 100;

            // 期望值(与 result_quantizer 相同的舍入/饱和公式)
            for (i = 0; i < m; i = i + 1)
                for (j = 0; j < n; j = j + 1) begin
                    acc = 0;
                    for (kk = 0; kk < k; kk = kk + 1)
                        acc = acc + Am[i][kk] * Bt[j][kk];
                    if (qs == 0) qt = acc;
                    else begin
                        qt = acc;
                        qt = (qt + (64'sd1 << (qs - 1))) >>> qs;
                    end
                    if      (qt >  64'sd2147483647) Ex[i][j] =  2147483647;
                    else if (qt < -64'sd2147483648) Ex[i][j] = -2147483648;
                    else                            Ex[i][j] = qt;
                end

            // 清除上一次 DONE
            cpu_wr(A_CTRL, 32'h2);

            // 装载 A/BT 并配置
            load_ab(0);
            load_ab(1);
            cpu_wr(A_M, m); cpu_wr(A_N, n); cpu_wr(A_K, k);
            cpu_wr(A_TM, tm); cpu_wr(A_TN, tn); cpu_wr(A_TK, tk);
            cpu_wr(A_QUANT, qs);

            // 启动并轮询 DONE
            t_start = cycle_cnt;
            cpu_wr(A_CTRL, 32'h1);
            timeout = 0;
            status = 32'd0;
            while (!(status[1]) && timeout < 20000) begin
                cpu_rd(A_STATUS, status);
                timeout = timeout + 1;
            end
            t_end = cycle_cnt;

            if (!status[1]) begin
                num_fail = num_fail + 1;
                $display("[%0s] FAIL : 超时未完成", name);
            end else if (status[2]) begin
                num_fail = num_fail + 1;
                $display("[%0s] FAIL : 意外 ERROR=1", name);
            end else begin
                // 读回比对
                errs = 0;
                for (i = 0; i < m; i = i + 1)
                    for (j = 0; j < n; j = j + 1) begin
                        cpu_rd(C_BUF + (i * n + j) * 4, rdw);
                        if (rdw !== Ex[i][j][31:0]) begin
                            errs = errs + 1;
                            if (errs <= 3)
                                $display("  C[%0d][%0d] = %0d (0x%08h), 期望 %0d",
                                         i, j, $signed(rdw), rdw, Ex[i][j]);
                        end
                    end
                if (errs == 0) begin
                    num_pass = num_pass + 1;
                    $display("[%0s] PASS : M=%0d N=%0d K=%0d TM=%0d TN=%0d TK=%0d q=%0d | C 写 %0d 项, 计算耗时 %0d 周期",
                             name, m, n, k, tm, tn, tk, qs, m * n, t_end - t_start);
                end else begin
                    num_fail = num_fail + 1;
                    $display("[%0s] FAIL : %0d 处结果错误", name, errs);
                end
            end
        end
    endtask

    // ---------------- 错误路径测试 ----------------
    task run_err_test(input [127:0] name, input integer m, n, k, tm, tn, tk, exp_code);
        begin
            cpu_wr(A_CTRL, 32'h2);
            cpu_wr(A_M, m); cpu_wr(A_N, n); cpu_wr(A_K, k);
            cpu_wr(A_TM, tm); cpu_wr(A_TN, tn); cpu_wr(A_TK, tk);
            cpu_wr(A_QUANT, 0);
            cpu_wr(A_CTRL, 32'h1);

            timeout = 0; status = 32'd0;
            while (!(status[1]) && timeout < 2000) begin
                cpu_rd(A_STATUS, status);
                timeout = timeout + 1;
            end
            cpu_rd(A_ERR, rdw);
            if (status[1] && status[2] && rdw[7:0] == exp_code[7:0]) begin
                num_pass = num_pass + 1;
                $display("[%0s] PASS : DONE+ERROR, ERR_CODE=%0d", name, rdw[7:0]);
            end else begin
                num_fail = num_fail + 1;
                $display("[%0s] FAIL : status=%0h err_code=%0d (期望 %0d)",
                         name, status, rdw[7:0], exp_code);
            end
        end
    endtask

    // ---------------- 主流程 ----------------
    initial begin
        num_pass = 0; num_fail = 0; cycle_cnt = 0;
        repeat (5) @(negedge clk);
        rst_n = 1;
        repeat (2) @(negedge clk);

        $display("==== NPU INT8 GEMM 仿真开始 ====");

        run_gemm_test("T1_单tile_4x4x4     ", 4,  4,  4, 4, 4, 4, 0, 32'h1);
        run_gemm_test("T2_满规模_16x16x16  ", 16, 16, 16, 4, 4, 4, 0, 32'h2);
        run_gemm_test("T3_边界_6x7x9       ", 6,  7,  9, 4, 4, 3, 0, 32'h3);
        run_gemm_test("T4_小tile_5x5x6     ", 5,  5,  6, 2, 3, 3, 0, 32'h4);
        run_gemm_test("T5_量化_8x8x8_q2    ", 8,  8,  8, 4, 4, 8, 2, 32'h5);
        run_err_test ("T6_零维错误         ", 0,  4,  4, 4, 4, 4, 1);
        run_err_test ("T7_超容量错误       ", 8,  8, 40, 4, 4, 16, 3);

        $display("==== 结果: PASS=%0d FAIL=%0d ====", num_pass, num_fail);
        if (num_fail == 0) $display("ALL TESTS PASSED");
        else               $display("SOME TESTS FAILED");
        $finish;
    end

    // 全局看门狗
    initial begin
        #10_000_000;
        $display("GLOBAL TIMEOUT");
        $finish;
    end

endmodule
