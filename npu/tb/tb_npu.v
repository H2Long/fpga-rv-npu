// tb_npu — NPU 系统行为测试台（回归网）
//
// 通过 AHB-Lite 从机接口装载 A/BT、配置参数、启动、轮询 DONE、读回 C 并与
// 期望值比对。cpu_wr/cpu_rd 就是 AHB-Lite 主端事务模型（地址阶段 + 数据阶段）。
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
//   AH  AHB-Lite 协议专项：背靠背流水写/读、未映射地址、非 32 位访问、忙时访问 Buffer
//
// 数据布局（k 主序、行进字节）：A/BT Buffer 的第 (g*K + k) 个字，
// 字节 b = 矩阵第 g*4 + b 行(列)在第 k 步的 INT8 值。
`timescale 1ns/1ps

module tb_npu;

    localparam TM_TN = 4;              // 硬件固定 TM=TN=4

    // ---------------- 寄存器地址（AHB 基址 + 内部偏移）----------------
    localparam [31:0] ADDR_BASE = 32'h4000_0000;  // 必须与 npu_defines.vh 的 NPU_ADDR_BASE 一致
    localparam [31:0] A_CTRL   = ADDR_BASE + 32'h0000_0000;   // bit0 start / bit1 clear_done
    localparam [31:0] A_M      = ADDR_BASE + 32'h0000_0004;
    localparam [31:0] A_N      = ADDR_BASE + 32'h0000_0008;
    localparam [31:0] A_K      = ADDR_BASE + 32'h0000_000C;
    localparam [31:0] A_ACC    = ADDR_BASE + 32'h0000_0010;   // bit0 accumulate
    localparam [31:0] A_TK     = ADDR_BASE + 32'h0000_0018;
    localparam [31:0] A_QUANT  = ADDR_BASE + 32'h0000_001C;
    localparam [31:0] A_STATUS = ADDR_BASE + 32'h0000_0020;   // bit0 BUSY / bit1 DONE / bit3 RDY / bit4 ERROR
    localparam [31:0] A_BUF    = ADDR_BASE + 32'h0000_1000;
    localparam [31:0] BT_BUF   = ADDR_BASE + 32'h0000_2000;
    localparam [31:0] C_BUF    = ADDR_BASE + 32'h0000_3000;
    localparam [31:0] A_UNMAP  = ADDR_BASE + 32'h0000_4000;   // 未映射地址（A/BT/C 之外）

    localparam STATUS_BUSY  = 0;
    localparam STATUS_DONE  = 1;
    localparam STATUS_ERROR = 4;

    // ---------------- AHB-Lite 常量 ----------------
    localparam [1:0] HTRANS_IDLE   = 2'b00;
    localparam [1:0] HTRANS_NONSEQ = 2'b10;
    localparam [1:0] HTRANS_SEQ    = 2'b11;
    localparam [1:0] HRESP_OKAY    = 2'b00;
    localparam [1:0] HRESP_ERROR   = 2'b01;

    // ---------------- AHB-Lite 主端信号 ----------------
    reg         HCLK;
    reg         HRESETn;
    reg         HSEL;
    reg  [31:0] HADDR;
    reg  [1:0]  HTRANS;
    reg         HWRITE;
    reg  [2:0]  HSIZE;
    reg  [31:0] HWDATA;
    wire [31:0] HRDATA;
    wire        HREADYOUT;
    wire [1:0]  HRESP;
    reg         HREADY;               // 单从机系统：全局 HREADY 回接 HREADYOUT

    integer cycle_cnt;
    integer ahb_err;      // 非预期 ERROR 响应计数
    integer ahb_stall;    // 背靠背流水期间的意外等待态计数

    npu_system dut(
        .HCLK(HCLK), .HRESETn(HRESETn),
        .HSEL(HSEL), .HADDR(HADDR), .HTRANS(HTRANS), .HWRITE(HWRITE),
        .HSIZE(HSIZE), .HWDATA(HWDATA), .HREADY(HREADY),
        .HRDATA(HRDATA), .HREADYOUT(HREADYOUT), .HRESP(HRESP)
    );

    always @(*) begin
        HREADY = HREADYOUT;           // 单从机：互连的全局 HREADY 就是本从机的 HREADYOUT
    end

    always #5 HCLK = ~HCLK;
    always @(posedge HCLK) cycle_cnt <= cycle_cnt + 1;

    initial begin
        $dumpfile("npu_wave.vcd");
        $dumpvars(0, tb_npu.dut);
    end

    // ---------------- 测试数据与统计 ----------------
    integer Am [0:63][0:63];   // A[M][K]
    integer Bt [0:63][0:63];   // BT[N][K]（B 的转置）
    integer Ex [0:63][0:63];   // 期望 C[M][N]
    integer pbuf [0:63];       // AHB 专项用例的流水写数据
    integer rbuf [0:63];       // AHB 专项用例的流水读结果

    integer num_pass, num_fail;
    integer i, j, kk, g, b;
    integer acc;
    reg signed [63:0] qt;
    reg [31:0] word, rdw, status;
    integer timeout, errs, t_start, t_end;

    integer m_r, n_r, k_r;

    initial begin
        HCLK = 1'b0;
        HRESETn = 1'b0;
        HSEL = 1'b0;
        HADDR = 32'd0;
        HTRANS = HTRANS_IDLE;
        HWRITE = 1'b0;
        HSIZE = 3'b010;
        HWDATA = 32'd0;
        HREADY = 1'b1;
        cycle_cnt = 0;
        ahb_err = 0;
        ahb_stall = 0;
        num_pass = 0;
        num_fail = 0;
    end

    // ---------------- AHB-Lite 主端访问任务 ----------------
    // 时序约定：所有主端输出在 negedge HCLK 更新，采样也在 negedge HCLK。
    // 地址阶段给出 HADDR/HTRANS/HWRITE，数据阶段给出 HWDATA 并等待 HREADYOUT。
    // 等待期间不改 HADDR/HTRANS/HWRITE（HREADY 低时 master 必须保持控制信号）。
    // 寄存器访问和 Buffer 写 0 等待（2 拍完成），Buffer 读多等 1 拍。
    task cpu_wr(input [31:0] a, input [31:0] d);
        begin
            @(negedge HCLK);
            HSEL = 1'b1; HADDR = a; HTRANS = HTRANS_NONSEQ; HWRITE = 1'b1; HSIZE = 3'b010;
            @(negedge HCLK);
            HWDATA = d;                              // 数据阶段
            while (!HREADYOUT) @(negedge HCLK);      // 等完成
            ahb_err = ahb_err + (HRESP != HRESP_OKAY);
            HTRANS = HTRANS_IDLE; HSEL = 1'b0;
        end
    endtask

    task cpu_rd(input [31:0] a, output [31:0] d);
        begin
            @(negedge HCLK);
            HSEL = 1'b1; HADDR = a; HTRANS = HTRANS_NONSEQ; HWRITE = 1'b0; HSIZE = 3'b010;
            @(negedge HCLK);
            while (!HREADYOUT) @(negedge HCLK);      // 等完成
            d = HRDATA;
            ahb_err = ahb_err + (HRESP != HRESP_OKAY);
            HTRANS = HTRANS_IDLE; HSEL = 1'b0;
        end
    endtask

    // 协议专项探测：返回最终 HRESP，并分别统计 ERROR 响应的两拍结构。
    // err_lo 应为 1（HRESP=ERROR 且 HREADYOUT=0 那一拍），err_hi 应为 1
    // （HRESP=ERROR 且 HREADYOUT=1 的完成拍）。sz 用来构造非 32 位访问。
    task ahb_probe(input [31:0] a, input wr, input [31:0] d, input [2:0] sz,
                   output [1:0] resp, output integer err_lo, output integer err_hi);
        integer guard;
        begin
            err_lo = 0; err_hi = 0; guard = 0; resp = HRESP_OKAY;
            @(negedge HCLK);
            HSEL = 1'b1; HADDR = a; HTRANS = HTRANS_NONSEQ; HWRITE = wr; HSIZE = sz;
            @(negedge HCLK);
            if (wr) HWDATA = d;
            while (!HREADYOUT && guard < 100) begin
                if (HRESP == HRESP_ERROR) err_lo = err_lo + 1;
                @(negedge HCLK);
                guard = guard + 1;
            end
            if (HRESP == HRESP_ERROR) err_hi = 1;
            resp = HRESP;
            HTRANS = HTRANS_IDLE; HSEL = 1'b0;
        end
    endtask

    // 背靠背流水写：地址每个周期前进一个字，写数据晚一拍给出，两者重叠。
    // 从机必须在"传输完成那一拍"接受下一笔地址，否则只会写入第 1、3、5… 个字。
    task ahb_pipelined_wr(input [31:0] base, input integer n, input integer seed);
        begin
            for (i = 0; i < n; i = i + 1)
                pbuf[i] = ({$random(seed)} % 201) - 100;
            @(negedge HCLK);
            for (i = 0; i < n; i = i + 1) begin
                HSEL   = 1'b1;
                HWRITE = 1'b1;
                HSIZE  = 3'b010;
                HADDR  = base + i * 4;
                HTRANS = (i == 0) ? HTRANS_NONSEQ : HTRANS_SEQ;
                if (i > 0) HWDATA = pbuf[i-1];
                @(negedge HCLK);
                if (!HREADYOUT) ahb_stall = ahb_stall + 1;
            end
            HWDATA = pbuf[n-1]; HTRANS = HTRANS_IDLE; HSEL = 1'b0;
            @(negedge HCLK);
            if (!HREADYOUT) ahb_stall = ahb_stall + 1;
        end
    endtask

    // 背靠背流水读：地址阶段连续驱动，HREADYOUT 拉高那一拍采样数据并换下一个地址。
    // Buffer 读有 1 拍等待，等待期间 master 必须保持地址，所以下一笔地址是在
    // S_RDD（数据返回拍）才被从机接受的——这条路径与 0 等待写不同，单独覆盖。
    task ahb_pipelined_rd(input [31:0] base, input integer n);
        begin
            @(negedge HCLK);
            HSEL = 1'b1; HWRITE = 1'b0; HSIZE = 3'b010;
            HADDR = base; HTRANS = HTRANS_NONSEQ;
            for (i = 0; i < n; i = i + 1) begin
                @(negedge HCLK);
                while (!HREADYOUT) @(negedge HCLK);
                rbuf[i] = HRDATA;
                if (i < n - 1) begin
                    HADDR  = base + (i + 1) * 4;
                    HTRANS = HTRANS_SEQ;
                end else begin
                    HTRANS = HTRANS_IDLE;
                    HSEL   = 1'b0;
                end
            end
            @(negedge HCLK);
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
            repeat (10) @(negedge HCLK);
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

    // ---------------- AHB-Lite 协议专项 ----------------
    integer rd_errs, lo, hi, ok;
    reg [1:0] resp;

    // AH1：背靠背流水写 16 个字 -> 逐字读回比对，并检查期间没有等待态。
    task ahb_test_pipelined;
        begin
            ahb_stall = 0;
            ahb_pipelined_wr(A_BUF, 16, 32'hC1);
            rd_errs = 0;
            for (i = 0; i < 16; i = i + 1) begin
                cpu_rd(A_BUF + i * 4, rdw);
                if (rdw !== pbuf[i][31:0]) begin
                    rd_errs = rd_errs + 1;
                    if (rd_errs <= 3)
                        $display("    A[%0d] = 0x%08h, 期望 0x%08h", i, rdw, pbuf[i][31:0]);
                end
            end
            ok = (rd_errs == 0) && (ahb_stall == 0) && (ahb_err == 0);
            if (ok) begin
                num_pass = num_pass + 1;
                $display("[AH1_背靠背流水写      ] PASS : 16 字全部写入并读回正确, 无等待态");
            end
            else begin
                num_fail = num_fail + 1;
                $display("[AH1_背靠背流水写      ] FAIL : 回读错 %0d 处, 等待态 %0d 次, 意外 ERROR %0d 次",
                         rd_errs, ahb_stall, ahb_err);
            end
        end
    endtask

    // AH2：未映射地址必须回 ERROR，且 ERROR 必须严格两拍（HREADYOUT=0 一拍 + =1 一拍）。
    task ahb_test_unmapped;
        begin
            ahb_probe(A_UNMAP, 1'b0, 32'd0, 3'b010, resp, lo, hi);
            if ((resp == HRESP_ERROR) && (lo == 1) && (hi == 1)) begin
                num_pass = num_pass + 1;
                $display("[AH2_未映射地址ERROR   ] PASS : HRESP=ERROR, 两拍结构 (lo=%0d hi=%0d)", lo, hi);
            end
            else begin
                num_fail = num_fail + 1;
                $display("[AH2_未映射地址ERROR   ] FAIL : HRESP=%b, 两拍结构 lo=%0d hi=%0d (期望 1/1)",
                         resp, lo, hi);
            end
        end
    endtask

    // AH3：非 32 位字访问（HSIZE=000）必须回 ERROR，而不是静默按字处理。
    task ahb_test_bad_size;
        begin
            ahb_probe(A_M, 1'b1, 32'd4, 3'b000, resp, lo, hi);
            if ((resp == HRESP_ERROR) && (lo == 1) && (hi == 1)) begin
                num_pass = num_pass + 1;
                $display("[AH3_非32位访问ERROR   ] PASS : HSIZE=000 被拒绝, 两拍结构正确");
            end
            else begin
                num_fail = num_fail + 1;
                $display("[AH3_非32位访问ERROR   ] FAIL : HRESP=%b lo=%0d hi=%0d", resp, lo, hi);
            end
        end
    endtask

    // AH4：core_busy 期间访问 A/BT/C Buffer 必须回 ERROR（旧设计会静默丢弃却应答成功）。
    task ahb_test_busy_buf;
        begin
            // 用 16x16x16 起一个长时间任务，先等 BUSY=1
            m_r = 16; n_r = 16;
            gen_data(16, 16, 16, 32'hD1);
            cpu_wr(A_CTRL, 32'h2);
            load_ab(0, 0, 16);
            load_ab(1, 0, 16);
            cpu_wr(A_M, 16); cpu_wr(A_N, 16); cpu_wr(A_K, 16);
            cpu_wr(A_TK, 4); cpu_wr(A_QUANT, 0); cpu_wr(A_ACC, 0);
            cpu_wr(A_CTRL, 32'h1);
            status = 32'd0;
            timeout = 0;
            while (!status[STATUS_BUSY] && timeout < 20) begin
                cpu_rd(A_STATUS, status);
                timeout = timeout + 1;
            end
            ok = status[STATUS_BUSY] && !status[3];      // BUSY=1 且 BUFFER_READY=0
            ahb_probe(A_BUF, 1'b1, 32'hDEAD_BEEF, 3'b010, resp, lo, hi);
            ok = ok && (resp == HRESP_ERROR) && (lo == 1) && (hi == 1);
            if (ok) begin
                num_pass = num_pass + 1;
                $display("[AH4_忙时访问Buffer    ] PASS : BUSY 期间 Buffer 访问回 ERROR, BUFFER_READY=0");
            end
            else begin
                num_fail = num_fail + 1;
                $display("[AH4_忙时访问Buffer    ] FAIL : STATUS=0x%08h HRESP=%b lo=%0d hi=%0d",
                         status, resp, lo, hi);
            end
            // 等任务自然结束，保持 DUT 状态干净
            timeout = 0;
            while (!status[STATUS_DONE] && timeout < 200000) begin
                cpu_rd(A_STATUS, status);
                timeout = timeout + 1;
            end
            cpu_wr(A_CTRL, 32'h2);
        end
    endtask

    // AH5：背靠背流水读（带 1 拍等待），验证等待期间地址流水与数据一一对应。
    task ahb_test_pipelined_rd;
        begin
            ahb_pipelined_wr(A_BUF, 16, 32'hC2);     // 先写入已知图案（存 pbuf）
            for (i = 0; i < 16; i = i + 1) rbuf[i] = 32'd0;
            ahb_pipelined_rd(A_BUF, 16);             // 再流水读回（存 rbuf）
            rd_errs = 0;
            for (i = 0; i < 16; i = i + 1)
                if (rbuf[i] !== pbuf[i][31:0]) rd_errs = rd_errs + 1;
            if (rd_errs == 0) begin
                num_pass = num_pass + 1;
                $display("[AH5_背靠背流水读      ] PASS : 16 字流水读回与写入图案逐字一致");
            end
            else begin
                num_fail = num_fail + 1;
                $display("[AH5_背靠背流水读      ] FAIL : %0d/16 处读回错误", rd_errs);
            end
        end
    endtask

    // ---------------- 主流程 ----------------
    integer tk_scan;
    reg [31:0] st0, st1;

    initial begin
        repeat (5) @(negedge HCLK);
        HRESETn = 1'b1;
        repeat (2) @(negedge HCLK);

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

            // AH：AHB-Lite 协议专项
            $display("---- AH AHB-Lite 协议专项（背靠背流水 / 错误响应）----");
            ahb_test_pipelined;
            ahb_test_pipelined_rd;
            ahb_test_unmapped;
            ahb_test_bad_size;
            ahb_test_busy_buf;

            // 非法配置之后必须能正常恢复
            run_gemm_test("GC_非法配置后恢复    ", 4, 4, 4, 4, 0, 32'hB);
        end

        $display("==== 结果: PASS=%0d FAIL=%0d ====", num_pass, num_fail);
        if (ahb_err != 0)
            $display("==== 非预期 AHB ERROR 响应: %0d 次 ====", ahb_err);
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
