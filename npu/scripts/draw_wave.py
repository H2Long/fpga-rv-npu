# -*- coding: utf-8 -*-
# draw_wave.py — 从 npu_wave.vcd 提取 T1(4×4×4 单 tile)的运行波形
# 输出: ../figures/NPU_T1运行波形.png / .svg
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle
import os

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei"]
plt.rcParams["axes.unicode_minus"] = False

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
VCD = os.path.join(PROJECT, "sim", "waves", "npu_wave.vcd")
OUT = os.path.join(PROJECT, "figures")
os.makedirs(OUT, exist_ok=True)

# ---------------- VCD 解析 ----------------
def parse_vcd(path):
    scopes = []
    paths = {}         # id -> [完整路径名(同一网络可能有多个层次别名)]
    changes = {}       # id -> [(t, val)]
    cur = None
    with open(path, "r", errors="ignore") as fh:
        in_defs = True
        for line in fh:
            line = line.strip()
            if in_defs:
                if line.startswith("$scope"):
                    scopes.append(line.split()[2])
                elif line.startswith("$upscope"):
                    scopes.pop()
                elif line.startswith("$var"):
                    parts = line.split()
                    vid = parts[3]
                    name = parts[4]
                    paths.setdefault(vid, []).append(".".join(scopes + [name]))
                elif line.startswith("$enddefinitions"):
                    in_defs = False
            else:
                if not line or line[0] == "$":
                    continue
                if line[0] == "#":
                    cur = int(line[1:])
                elif line[0] in "01xz":
                    vid = line[1:]
                    changes.setdefault(vid, []).append((cur, line[0]))
                elif line[0] == "b":
                    val, vid = line[1:].split()
                    changes.setdefault(vid, []).append((cur, val))
    return paths, changes

paths, changes = parse_vcd(VCD)

def find(parent, name):
    """精确 '父路径.信号名' 优先,其次父路径下的深层实例名"""
    exact = f"{parent}.{name}"
    for vid, ps in paths.items():
        if exact in ps:
            return vid
    for vid, ps in paths.items():
        for p in ps:
            if p.endswith("." + name) and p.startswith(parent + "."):
                return vid
    # 最后兜底:任意位置的名字
    for vid, ps in paths.items():
        for p in ps:
            if p.endswith("." + name):
                return vid
    return None

def get_series(parent, name):
    vid = find(parent, name)
    if vid is None:
        print("MISS:", parent, name)
        return []
    return changes.get(vid, [])

def sig(parent, name):
    return get_series(parent, name)

S = "tb_npu.dut"
series = {
    "start_pulse":     sig(S + ".u_npu_top.u_start_ctrl", "start_pulse"),
    "core_busy":       sig(S + ".u_tile_controller", "core_busy"),
    "fsm_state":       sig(S + ".u_tile_controller.u_systolic_fsm", "state"),
    "pf_start":        sig(S + ".u_tile_controller.u_systolic_fsm", "pf_start"),
    "a_fifo_count":    sig(S + ".u_tile_controller", "a_fifo_count"),
    "pair_fire":       sig(S + ".u_tile_controller", "pair_fire"),
    "array_enable":    sig(S + ".u_tile_controller", "array_enable"),
    "acc_clear":       sig(S + ".u_tile_controller", "acc_clear"),
    "drain_en":        sig(S + ".u_tile_controller", "drain_en"),
    "drain_done":      sig(S + ".u_tile_controller", "drain_done"),
    "cwr_scan":        sig(S + ".u_tile_controller.u_c_tile_write_ctrl", "cwr_valid_out"),
    "cwr_valid":       sig(S + ".u_tile_controller", "cwr_valid"),
    "c_wr_pulse":      sig(S + ".u_npu_buffer.u_c_write_fifo", "c_wr_pulse"),
    "core_done":       sig(S + ".u_tile_controller", "core_done"),
    "cpu_valid":       sig(S, "cpu_valid"),
}

# ---------------- 时间窗:T1 的 start_pulse 到 core_done ----------------
def first_high(ser):
    for t, v in ser:
        if v in ("1",):
            return t
    return None

def first_pulse_ge(ser, t0):
    prev = "0"
    for t, v in ser:
        if t >= t0 and prev != "1" and v == "1":
            return t
        prev = v
    return None

t_start = first_high(series["start_pulse"])
t_done = first_pulse_ge(series["core_done"], t_start)
print("T1 window(ns):", t_start / 1000, "->", t_done / 1000)
T0, T1_ = t_start - 60000, t_done + 220000   # ps,前后留观察余量

def window_vals(ser, t0, t1):
    """返回 [(t, v)] 在 [t0,t1] 内的值序列,含窗外最后一个旧值"""
    out = []
    last = None
    for t, v in ser:
        if t <= t0:
            last = (t0, v)
        elif t < t1:
            if last is not None:
                out.append(last)
                last = None
            out.append((t, v))
        else:
            break
    if last is not None:
        out.append(last)
    if not out or out[0][0] > t0:
        v0 = "0"
        for t, v in ser:
            if t <= t0:
                v0 = v
            else:
                break
        out.insert(0, (t0, v0))
    out.append((t1, out[-1][1] if out else "0"))
    return out

# v2.1 的 7 个状态（S_IDLE/S_INIT/S_CLEAR_ACC/S_PREFETCH/S_FEED/S_DRAIN/S_DONE）
STATE_NAMES = ["IDLE", "INIT", "CLEAR_ACC", "PREFETCH", "FEED", "DRAIN", "DONE"]

# ---------------- 绘制 ----------------
rows = [
    ("cpu_valid (MMIO 活动)", "cpu_valid", "bit"),
    ("start_pulse", "start_pulse", "bit"),
    ("core_busy", "core_busy", "bit"),
    ("systolic_fsm.state", "fsm_state", "state"),
    ("pf_start (K Tile 预取)", "pf_start", "bit"),
    ("a_fifo_count[6:0]", "a_fifo_count", "bus"),
    ("pair_fire (A/BT 成对)", "pair_fire", "bit"),
    ("array_enable", "array_enable", "bit"),
    ("acc_clear (每输出 Tile 一次)", "acc_clear", "bit"),
    ("drain_en", "drain_en", "bit"),
    ("drain_done", "drain_done", "bit"),
    ("cwr_valid_out (快照写回)", "cwr_scan", "bit"),
    ("cwr_valid (写 FIFO)", "cwr_valid", "bit"),
    ("c_wr_pulse (落 C RAM)", "c_wr_pulse", "bit"),
    ("core_done", "core_done", "bit"),
]

C_HI, C_LO = "#2F6FBF", "#B8CADF"
C_TXT = "#1F2328"

fig, ax = plt.subplots(figsize=(19, 10.5), dpi=200)
n = len(rows)
LW = 2.0
for i, (label, key, kind) in enumerate(rows):
    y = n - i - 1
    wv = window_vals(series[key], T0, T1_)
    if kind == "bit":
        pts_t, pts_v = [], []
        for t, v in wv:
            pts_t.append(t / 1000)
            pts_v.append(1 if v == "1" else 0)
        ax.step(pts_t, [y + v * 0.72 for v in pts_v], where="post",
                color=C_HI if True else C_LO, lw=LW)
    elif kind == "bus":
        ax.plot([T0/1000, T1_/1000], [y + 0.36, y + 0.36], color="#9AA4B2", lw=0)
        prev = None
        for t, v in wv:
            if prev is not None:
                ax.plot([prev[0]/1000, t/1000], [y + 0.3, y + 0.3], color="#57606A", lw=5.0,
                        solid_capstyle="butt", alpha=0.35)
                ax.text((prev[0] + (t - prev[0]) / 2) / 1000, y + 0.3,
                        str(int(prev[1], 2) if prev[1] not in "xz" else prev[1]),
                        fontsize=7.4, ha="center", va="center", color="#24292F",
                        bbox=dict(boxstyle="round,pad=0.1", fc="white", ec="none", alpha=0.75))
            prev = (t, v)
        if prev is not None:
            ax.plot([prev[0]/1000, T1_/1000], [y + 0.3, y + 0.3], color="#57606A", lw=5.0,
                    solid_capstyle="butt", alpha=0.35)
    elif kind == "state":
        prev = None
        for t, v in wv:
            if prev is not None and prev[1] not in "xz":
                idx = int(prev[1], 2)
                nm = STATE_NAMES[idx] if idx < len(STATE_NAMES) else str(idx)
                x0, x1 = prev[0]/1000, t/1000
                band = {"FEED": "#DCEAF8", "DRAIN": "#E3F1E8", "WRITE_C": "#FDEBD7",
                        "PREFETCH": "#FFF3D6", "ARR_START": "#FDE4E1"}.get(nm, "#F0F2F5")
                ax.add_patch(Rectangle((x0, y + 0.08), x1 - x0, 0.62, fc=band,
                                       ec="#57606A", lw=0.7))
                if x1 - x0 > 22:
                    ax.text((x0 + x1)/2, y + 0.39, nm, fontsize=7.6, ha="center",
                            va="center", color="#24292F")
            prev = (t, v)

# 标出 start / done 时刻
ax.axvline(t_start / 1000, color="#C0392B", lw=1.4, ls=(0, (4, 3)), alpha=0.8)
ax.text(t_start / 1000 + 6, n - 0.25, "写 CTRL.start", fontsize=9.5, color="#C0392B")
ax.axvline(t_done / 1000, color="#1E7D4F", lw=1.4, ls=(0, (4, 3)), alpha=0.8)
ax.text(t_done / 1000 - 6, n - 0.25, "core_done\n(最后一笔 C 已落 RAM)", fontsize=9.5,
        color="#1E7D4F", ha="right")

ax.set_yticks([n - i - 1 + 0.36 for i in range(n)])
ax.set_yticklabels([r[0] for r in rows], fontsize=10)
ax.set_ylim(-0.4, n + 0.35)
ax.set_xlim(T0 / 1000, T1_ / 1000)
ax.set_xlabel("时间 (ns)   ·   时钟 10 ns/周期   ·   T1: M=N=K=4, TM=TN=TK=4, 单 tile", fontsize=11)
ax.xaxis.grid(True, which="major", color="#D8DEE4", lw=0.7)
for s in ("top", "right"):
    ax.spines[s].set_visible(False)
ax.set_title("NPU 一次任务的实测运行波形(Icarus Verilog 仿真, 从 npu_wave.vcd 提取)",
             fontsize=15, weight="bold", color=C_TXT, pad=12)
ax.tick_params(axis="both", labelsize=9)

fig.text(0.5, 0.012,
         "流程可见:预取(a_fifo_count 0→4)→ 喂数(pair_fire ×4 拍)→ 排空 6 拍(drain_done)→ "
         "16 拍结果流(c_result_valid)→ 16 笔 C 写(c_wr_pulse)→ core_done",
         fontsize=10.5, ha="center", color="#57606A")

plt.subplots_adjust(left=0.185, right=0.99, top=0.93, bottom=0.075)
fig.savefig(os.path.join(OUT, "NPU_T1运行波形.png"), dpi=200, facecolor="white")
fig.savefig(os.path.join(OUT, "NPU_T1运行波形.svg"), facecolor="white")
print("OK")
