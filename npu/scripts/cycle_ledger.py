# cycle_ledger.py — NPU 周期账本：打印每个任务的 FSM 阶段拍数与停顿原因
#
# 用法:
#   python3 scripts/cycle_ledger.py            # 全量回归
#   python3 scripts/cycle_ledger.py --simple   # 只跑 G1 单 Tile
#   python3 scripts/cycle_ledger.py --keep     # 保留临时目录（含波形与编译产物）
#
# 做法: 在临时目录里生成一个只读监视器 mon_top（例化 tb_npu，统计 systolic_fsm
#       各状态的拍数与停顿原因），和 RTL/tb 一起编译运行。监视器不修改任何 RTL，
#       也不需要改动 tb_npu.v；波形与中间产物都落在临时目录，不会覆盖 sim/。
#
# 为什么要这个工具: 优化 RTL 时"感觉变快了"不算数，必须能说清省下的是哪一段。
# 账本的每一项都对应一个具体的等待原因：
#   clearwait  等快照 bank（c_tile_write_ctrl 的扫描占用）
#   prefwait   等 A/BT 预取 FIFO 到齐
#   feedstall  喂数时 FIFO 空转
#   drain      每个输出 Tile 的阵列排空
#   有效喂数 = feed - feedstall，它才是真正在算的拍
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
RTL = os.path.join(PROJECT, "rtl")
TB = os.path.join(PROJECT, "tb")

# 只读监视器：统计 systolic_fsm 每拍落在哪个状态，以及停顿原因。
# 层次路径与 tb_npu.v 的实例名绑定（tb_npu.dut -> npu_system）。
MONITOR = r"""
`timescale 1ns/1ps
`include "npu_defines.vh"
module mon_top;
    tb_npu u_tb();

    wire clk = u_tb.HCLK;
    wire [2:0] st   = u_tb.dut.u_tile_controller.u_systolic_fsm.state;
    wire       pfrd = u_tb.dut.u_tile_controller.u_systolic_fsm.prefetch_done;
    wire       snpr = u_tb.dut.u_tile_controller.u_systolic_fsm.snap_ready;
    wire       pair = u_tb.dut.u_tile_controller.pair_fire;
    wire       cap  = u_tb.dut.u_tile_controller.u_c_tile_write_ctrl.cap_fire;
    wire       scan = u_tb.dut.u_tile_controller.u_c_tile_write_ctrl.scan_start;
    wire       push = u_tb.dut.u_tile_controller.cwr_valid;
    wire [1:0] busy = u_tb.dut.u_tile_controller.u_c_tile_write_ctrl.bank_busy_q;
    // 任务参数直接从 RTL 取，避免依赖解析测试台的 PASS 文本（累加用例的 PASS 行
    // 里没有 M=.. N=.. K=..，按文本归属会把两个分段算到上一条用例头上）
    wire [`NPU_DIM_W-1:0] cfg_m = u_tb.dut.u_tile_controller.cfg_m;
    wire [`NPU_DIM_W-1:0] cfg_n = u_tb.dut.u_tile_controller.cfg_n;
    wire [`NPU_DIM_W-1:0] cfg_k = u_tb.dut.u_tile_controller.cfg_k;
    wire [`NPU_TK_W-1:0]  cfg_tk = u_tb.dut.u_tile_controller.cfg_tk;

    reg [2:0] pst;
    integer ntask, task_cyc, n_init, n_clear, w_clear, n_pref, w_pref;
    integer n_feed, w_feed, n_drain, n_done, n_cap, n_scan, n_push, maxbusy;

    task reset_cnt;
        begin
            task_cyc = 0; n_init = 0; n_clear = 0; w_clear = 0;
            n_pref = 0; w_pref = 0; n_feed = 0; w_feed = 0;
            n_drain = 0; n_done = 0; n_cap = 0; n_scan = 0; n_push = 0;
        end
    endtask

    initial begin
        reset_cnt; ntask = 0; pst = 3'd0; maxbusy = 0;
    end

    always @(posedge clk) begin
        if (u_tb.HRESETn == 1'b0) begin
            pst <= st;
        end
        else begin
            // 任务结束：FSM 从 S_DONE 回到 S_IDLE（core_done）。此时 cfg_* 仍然是
            // 本任务的参数（npu_top 在下次 start 之前一直保持锁存值）。
            if (st == 3'd0 && pst == 3'd6) begin
                ntask = ntask + 1;
                $display("LEDGER n=%0d m=%0d n=%0d k=%0d tk=%0d core=%0d init=%0d clear=%0d clearwait=%0d pref=%0d prefwait=%0d feed=%0d feedstall=%0d drain=%0d done=%0d cap=%0d scan=%0d push=%0d maxbusy=%0d",
                         ntask, cfg_m, cfg_n, cfg_k, cfg_tk,
                         task_cyc, n_init, n_clear, w_clear, n_pref, w_pref,
                         n_feed, w_feed, n_drain, n_done, n_cap, n_scan, n_push, maxbusy);
                reset_cnt;
            end
            if (st != 3'd0) task_cyc = task_cyc + 1;   // 只数 FSM 非空闲拍
            case (st)
                3'd1: n_init  = n_init  + 1;
                3'd2: begin n_clear = n_clear + 1; if (!snpr) w_clear = w_clear + 1; end
                3'd3: begin n_pref  = n_pref  + 1; if (!pfrd) w_pref  = w_pref  + 1; end
                3'd4: begin n_feed  = n_feed  + 1; if (!pair) w_feed  = w_feed  + 1; end
                3'd5: n_drain = n_drain + 1;
                3'd6: n_done  = n_done  + 1;
                default: ;
            endcase
            if (cap)  n_cap  = n_cap  + 1;
            if (scan) n_scan = n_scan + 1;
            if (push) n_push = n_push + 1;
            if ((busy[0] + busy[1]) > maxbusy) maxbusy = busy[0] + busy[1];
            pst <= st;
        end
    end
endmodule
"""


def find_iverilog():
    exe = shutil.which("iverilog")
    if exe:
        return exe
    sys.exit("未找到 iverilog,请安装 Icarus Verilog 并加入 PATH")


def pe_num():
    """从 npu_defines.vh 读 PE 总数，用于计算阵列利用率。"""
    path = os.path.join(RTL, "common", "npu_defines.vh")
    with open(path, encoding="utf-8", errors="replace") as fh:
        m = re.search(r"`define\s+NPU_PE_NUM\s+(\d+)", fh.read())
    return int(m.group(1)) if m else 16


def main():
    simple = "--simple" in sys.argv[1:]
    keep = "--keep" in sys.argv[1:]

    files = sorted(
        os.path.join(root, name)
        for root, _, names in os.walk(RTL)
        for name in names
        if name.endswith(".v")
    )
    files.append(os.path.join(TB, "tb_npu.v"))

    tmp = tempfile.mkdtemp(prefix="npu_ledger_")
    mon = os.path.join(tmp, "mon_ledger.v")
    with open(mon, "w", encoding="utf-8") as fh:
        fh.write(MONITOR)

    vvp = os.path.join(tmp, "mon.vvp")
    cmd = [find_iverilog(), "-g2005", "-I", os.path.join(RTL, "common"), "-o", vvp] + files + [mon]
    r = subprocess.run(cmd, cwd=PROJECT, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if r.returncode != 0:
        print(r.stdout + r.stderr)
        sys.exit("编译失败")

    sim = [vvp]
    if simple:
        sim.append("+ONLY_T1")
    r = subprocess.run(sim, cwd=tmp, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr

    # 解析：按输出出现顺序处理。LEDGER 行是在"下一个任务开始"时打印的，
    # 所以它属于紧邻它之前的那条 PASS/FAIL 行；一次 PASS 可能对应多个 LEDGER
    # （例如跨任务累加用例跑两段），把它们累加到一起。
    # LEDGER 在任务结束时打印，紧接着才是该任务的 PASS/FAIL 行（跨任务累加用例会
    # 先连续打印两个分段的 LEDGER，再打印一条 PASS），所以先把 LEDGER 缓存起来，
    # 遇到 PASS/FAIL 时再一起挂上去。行数、M/N/K/TK 全部取自 RTL 侧的 LEDGER。
    # 归属：TB 在每个 NPU 任务开始处打印 TASK_BEGIN（带用例名与 M/N/K/TK），
    # 监视器在任务结束时打印 LEDGER。两者按出现顺序 FIFO 一一配对，不依赖解析
    # PASS 文本（跨任务累加用例一条 PASS 对应两个分段，AH4 的账本又晚于它的 PASS，
    # 按文本归属都会错位）。
    tasks = []
    queue = []
    for line in out.splitlines():
        if line.startswith("TASK_BEGIN"):
            fields = dict(re.findall(r"(\w+)=(\d+)", line))
            name = line.split()[1] if len(line.split()) > 1 else "?"
            queue.append({"name": name, "m": int(fields.get("m", 0)),
                          "n": int(fields.get("n", 0)), "k": int(fields.get("k", 0)),
                          "tk": int(fields.get("tk", 0)), "ledgers": []})
            tasks.append(queue[-1])
            continue
        if line.startswith("LEDGER"):
            led = {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", line)}
            # 挂到最靠前的、还缺账本的任务上
            for rec in queue:
                if not rec["ledgers"]:
                    rec["ledgers"].append(led)
                    break

    def dwidth(txt):
        return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in txt)

    def pad(txt, width):
        return txt + " " * max(0, width - dwidth(txt))

    pe = pe_num()
    hdr = ["任务", "M x N x K (TK)", "核心拍", "有效喂数", "等快照", "等预取",
           "喂数空转", "排空", "其它", "利用率"]
    rows, tot, maxbusy = [], {k: 0 for k in ("core", "feed", "feedstall", "clearwait",
                                             "prefwait", "drain", "done", "cap", "scan",
                                             "push")}, 0
    for t in tasks:
        if not t["ledgers"]:
            rows.append([t["name"]] + ["-"] * 9)
            continue
        led = {k: sum(g.get(k, 0) for g in t["ledgers"]) for k in tot}
        led["maxbusy"] = max(g.get("maxbusy", 0) for g in t["ledgers"])
        first = t["ledgers"][0]
        m, n, k, tk = first["m"], first["n"], first["k"], first["tk"]
        feed_ok = led["feed"] - led["feedstall"]
        # 其它 = 各状态的正常通过拍（init / clear 通过 / prefetch 通过 / 结束等待）
        other = (led["core"] - led["feed"] - led["drain"] - led["clearwait"]
                 - led["prefwait"] - led["feedstall"])
        util = m * n * k * 100.0 / (led["core"] * pe) if led["core"] else 0.0
        seg = f" x{len(t['ledgers'])}" if len(t["ledgers"]) > 1 else ""
        rows.append([t["name"] + seg, f"{m}x{n}x{k} TK{tk}", str(led["core"]),
                     str(feed_ok), str(led["clearwait"]), str(led["prefwait"]),
                     str(led["feedstall"]), str(led["drain"]), str(other), f"{util:.1f}%"])
        for kk in tot:
            tot[kk] += led[kk]
        maxbusy = max(maxbusy, led["maxbusy"])

    widths = [max(dwidth(r[i]) for r in rows + [hdr]) for i in range(len(hdr))]
    widths[0] = min(widths[0], 28)
    line = "  ".join(pad(h, widths[i]) for i, h in enumerate(hdr))
    print(line)
    print("-" * dwidth(line))
    for r in rows:
        print("  ".join(pad(tuple(r)[i][:60], widths[i]) for i in range(len(hdr))))

    print()
    if tot["core"]:
        ntask = len([r for r in rows if r[2] != "-"])
        print(f"合计（{ntask} 个任务的 FSM 拍数；不含任务之间的 CPU 装载时间）:")
        for k, v in (("有效喂数", tot["feed"] - tot["feedstall"]),
                     ("等快照 bank", tot["clearwait"]),
                     ("等预取", tot["prefwait"]),
                     ("喂数空转", tot["feedstall"]),
                     ("排空", tot["drain"]),
                     ("结束等待(等 C 落 RAM)", tot["done"]),
                     ("快照捕获", tot["cap"]),
                     ("扫描启动", tot["scan"]),
                     ("写 FIFO 入队", tot["push"])):
            print(f"  {pad(k, 22)}{v:>8}")
        print(f"  {pad('C bank 峰值占用', 22)}{maxbusy:>8} / 2")
        print()
        print(" 注: 一次排空只应产生 1 次捕获 = 1 次扫描。捕获数多于输出 Tile 数、或扫描启动")
        print("     次数是捕获的两倍，说明快照/扫描控制有问题（重复扫描在非累加模式下会因")
        print("     幂等而看不出来，累加模式会多加一次结果）。")

    print()
    for line_ in out.splitlines():
        if "结果:" in line_ or "ALL TESTS PASSED" in line_ or "SOME TESTS FAILED" in line_:
            print(line_.strip())

    if keep:
        print("\n临时目录保留在:", tmp)
    else:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
