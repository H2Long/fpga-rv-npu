# -*- coding: utf-8 -*-
# draw_arch.py — 绘制 NPU 总体架构图(45 模块 + 接线总表全部连线)
# 输出: ../figures/NPU_总体架构图.png / .svg
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Rectangle
import os

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei"]
plt.rcParams["axes.unicode_minus"] = False

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
OUT = os.path.join(PROJECT, "figures")
os.makedirs(OUT, exist_ok=True)

# ---------- 配色 ----------
C_TOP_BG,  C_TOP_BD  = "#EAF3FB", "#6E9CC5"   # npu_top 浅蓝
C_CTRL_BG, C_CTRL_BD = "#FFF8E4", "#B8964B"   # tile_controller 浅黄
C_BUF_BG,  C_BUF_BD  = "#EAF7EC", "#6FAF8B"   # npu_buffer 浅绿
C_MAC_BG,  C_MAC_BD  = "#F3EEFB", "#8F78BC"   # npu_mac 浅紫
C_CTRL = "#C0392B"   # 控制红
C_A    = "#1F5FA8"   # A 蓝
C_BT   = "#1E7D4F"   # BT 绿
C_C    = "#D97706"   # C 橙
C_STAT = "#73787F"   # 状态灰
C_MIX  = "#3C3F45"   # 混合黑
C_TXT  = "#1F2328"

W, H = 100.0, 76.0
Y_TOP, Y_BOT = -5.0, 78.5

fig, ax = plt.subplots(figsize=(22, 18.3), dpi=200)
ax.set_xlim(-0.5, W + 0.5)
ax.set_ylim(Y_BOT, Y_TOP)          # y 向下为正
ax.set_autoscale_on(False)
ax.axis("off")

# ---------- 基础绘制函数 ----------
def region(x, y, w, h, bg, bd, title, sub):
    ax.add_patch(FancyBboxPatch((x, y), w, h,
        boxstyle="round,pad=0.15,rounding_size=0.6",
        fc=bg, ec=bd, lw=1.7, zorder=1))
    ax.text(x + 0.9, y + 1.6, title, fontsize=13.5, weight="bold", color=bd, va="center")
    ax.text(x + w - 0.9, y + 1.6, sub, fontsize=9.0, color=bd, va="center", ha="right")

def box(x, y, w, h, name, sub, bd, fs=9.2, mono=True):
    ax.add_patch(FancyBboxPatch((x, y), w, h,
        boxstyle="round,pad=0.06,rounding_size=0.35",
        fc="white", ec=bd, lw=1.4, zorder=3))
    cy = y + h / 2
    fam = ["Consolas", "monospace"] if mono else None
    if sub:
        ax.text(x + w/2, cy - 0.68, name, fontsize=fs, weight="bold",
                ha="center", va="center", color=C_TXT, family=fam, zorder=4)
        ax.text(x + w/2, cy + 0.9, sub, fontsize=7.2, ha="center", va="center",
                color="#57606A", zorder=4)
    else:
        ax.text(x + w/2, cy, name, fontsize=fs, weight="bold",
                ha="center", va="center", color=C_TXT, family=fam, zorder=4)

def wire(pts, color, lw=1.3, arrow=True, ls="-", alpha=0.92):
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    ax.plot(xs, ys, color=color, lw=lw, ls=ls, alpha=alpha, zorder=2,
            solid_capstyle="round")
    if arrow:
        ax.annotate("", xy=pts[-1], xytext=pts[-2],
                    arrowprops=dict(arrowstyle="-|>", color=color, lw=lw,
                                    mutation_scale=12, alpha=alpha), zorder=2)

def wlabel(x, y, text, color, fs=7.0, ha="center"):
    ax.text(x, y, text, fontsize=fs, color=color, ha=ha, va="center", zorder=5,
            bbox=dict(boxstyle="round,pad=0.14", fc="white", ec="none", alpha=0.9))

# ---------- 标题 ----------
ax.text(W/2, -3.0, "NPU 矩阵乘法加速器总体架构", fontsize=22, weight="bold",
        ha="center", color=C_TXT)
ax.text(W/2, -0.4, "C[M][N] = A[M][K] × BT[N][K]   ·   INT8 输入 / 32 位累加   ·   4×4 脉动阵列   ·   26 个 RTL 文件(npu_top/tile_controller/npu_buffer/npu_mac + support)",
        fontsize=10, ha="center", color="#57606A")

# ---------- 区域 ----------
region(2, 3, 96, 18.5, C_TOP_BG,  C_TOP_BD,  "npu_top  —  CPU 控制平面", "MMIO · 寄存器 · 启动 · 访问仲裁")
region(2, 22.5, 57, 34.5, C_CTRL_BG, C_CTRL_BD, "tile_controller  —  调度与时序控制平面", "Tile 调度 · 地址生成 · systolic_fsm · C 写回")
region(61, 22.5, 37, 34.5, C_BUF_BG, C_BUF_BD, "npu_buffer  —  存储平面", "A/BT/C RAM · 预取/写 FIFO")
region(2, 58.5, 96, 17.0, C_MAC_BG, C_MAC_BD, "npu_mac  —  计算平面", "拆包 · 波前对齐 · PE 阵列 · 排空 · 收集")

# ---------- CPU(外部) ----------
box(3.2, 6.4, 6.5, 4.6, "CPU", "RISC-V 核", "#57606A", fs=11, mono=False)

# ---------- npu_top 模块 ----------
BW, BH = 12.5, 4.6
box(13,   6.4, BW, BH, "mmio_if",           "MMIO 总线入口", C_TOP_BD)
box(28.5, 6.4, BW, BH, "npu_top.decode",     "地址译码", C_TOP_BD, fs=8.0)
box(44,   6.4, BW, BH, "control_regs",      "配置寄存器", C_TOP_BD)
box(59.5, 6.4, BW, BH, "start_ctrl",        "任务生命周期", C_TOP_BD)
box(28.5, 14.2, BW, BH, "npu_top.status",   "BUSY/DONE", C_TOP_BD, fs=8.0)
box(44,   14.2, BW, BH, "buffer_access_ctrl", "仲裁/字节屏蔽/RAM端口", C_TOP_BD, fs=7.2)
ax.text(76.5, 8.9, "MMIO 映射\n0x0000  控制寄存器\n0x0020  状态寄存器\n0x1000  A Buffer\n0x2000  BT Buffer\n0x3000  C Buffer",
        fontsize=8.5, color="#3D648C", va="center", ha="left", zorder=4, linespacing=1.55,
        bbox=dict(boxstyle="round,pad=0.55", fc="white", ec=C_TOP_BD, lw=1.1))

# ---------- tile_controller 模块 ----------
CBW = 13.5
box(4,   25.5, CBW, BH + 1.1, "tile_controller.config", "参数快照复用", C_CTRL_BD, fs=7.0)
box(4,   32.3, CBW, BH, "tile_controller.bounds",   "边界尺寸派生", C_CTRL_BD, fs=7.8)
box(4,   39.1, CBW, BH, "tile_scheduler",   "i/j/k 三层循环", C_CTRL_BD, fs=8.2)
box(4,   45.9, CBW, BH + 1.1, "tile_controller.addr", "A/BT/C 基地址", C_CTRL_BD, fs=7.0)
box(20.5, 25.5, CBW, BH, "npu_stream_ctrl",  "A/BT 共用读流", C_CTRL_BD, fs=8.0)
box(20.5, 32.3, CBW, 10.2, "systolic_fsm",  "13 态主状态机\n预取→喂数→排空→收→写", C_CTRL_BD, fs=9.8)
ax.add_patch(FancyBboxPatch((20.5, 32.3), CBW, 10.2,
    boxstyle="round,pad=0.06,rounding_size=0.35", fc="none", ec=C_CTRL,
    lw=1.0, ls=(0, (2.2, 2.0)), zorder=3.5))
box(20.5, 45.9, CBW, BH, "c_tile_acc_ctrl", "K 向累加 16×32b", C_CTRL_BD, fs=7.8)
box(20.5, 52.0, CBW, BH, "done_ctrl",       "core_done 判定", C_CTRL_BD, fs=8.2)
box(37, 25.5, CBW, BH, "npu_stream_ctrl",     "A 读流实例", C_CTRL_BD, fs=8.2)
box(37, 32.3, CBW, BH, "npu_stream_ctrl",    "BT 读流实例", C_CTRL_BD, fs=8.2)
box(37, 39.1, CBW, BH, "pair_stream_ctrl",  "A/BT 成对送数", C_CTRL_BD, fs=7.8)
box(37, 45.9, CBW, BH, "FSM 组合译码",        "阵列周期控制", C_CTRL_BD, fs=8.2)
box(37, 52.0, CBW, BH, "c_tile_write_ctrl", "C 写回/越界过滤", C_CTRL_BD, fs=7.2)
box(4, 52.0, CBW, BH, "result_quantizer",   "舍入/移位/饱和", C_CTRL_BD, fs=7.4)

# ---------- npu_buffer 模块 ----------
BBW = 15.5
box(63, 25.5, BBW, BH, "npu_ram(A)",        "64×32 bit", C_BUF_BD)
box(63, 32.3, BBW, BH, "npu_ram(BT)",       "64×32 bit", C_BUF_BD)
box(63, 39.1, BBW, BH, "npu_ram(C)",        "256×32 bit", C_BUF_BD)
box(81.5, 25.5, BBW, BH, "npu_sync_fifo(A)", "吸收 RAM 延迟", C_BUF_BD, fs=7.2)
box(81.5, 32.3, BBW, BH, "npu_sync_fifo(BT)", "吸收 RAM 延迟", C_BUF_BD, fs=7.2)
box(81.5, 39.1, BBW, BH, "c_write_fifo",    "写回解耦", C_BUF_BD, fs=7.8)
box(63, 45.9, 17.5, BH, "npu_buffer.read_delay", "同步读→FIFO", C_BUF_BD, fs=6.8)

# ---------- npu_mac 模块 ----------
box(6,  61.6, 13.5, BH, "input_unpacker(A)",  "32b→4×INT8", C_MAC_BD, fs=7.6)
box(6,  68.6, 13.5, BH, "input_unpacker(BT)", "32b→4×INT8", C_MAC_BD, fs=7.2)
box(23, 61.6, 14.5, 11.6, "a_bt_skew_pipeline", "A 行 r 延迟 r 拍\nBT 列 c 延迟 c 拍", C_MAC_BD, fs=7.6)
px, py, pw, ph = 42, 61.6, 17.5, 11.6
box(px, py, pw, ph, "", "", C_MAC_BD)
ax.text(px + pw/2, py + 1.8, "pe_array", fontsize=10, weight="bold", ha="center",
        color=C_TXT, family=["Consolas", "monospace"], zorder=4)
gx0, gy0, cell = px + 2.9, py + 3.5, 1.75
for r in range(4):
    for c in range(4):
        ax.add_patch(Rectangle((gx0 + c*cell, gy0 + r*cell), cell*0.85, cell*0.85,
            fc="#EDE7F8", ec=C_MAC_BD, lw=0.7, zorder=4))
        ax.text(gx0 + c*cell + cell*0.42, gy0 + r*cell + cell*0.42, f"{r}{c}",
                fontsize=6.4, ha="center", va="center", color="#5B4A87", zorder=5)
ax.text(px + pw/2, py + ph - 0.8, "acc[r][c] += A[r][k]×BT[c][k]",
        fontsize=7.6, ha="center", color="#57606A", zorder=5)
box(63, 61.6, 13.5, BH, "drain_controller", "排空 P+Q-2=6 拍", C_MAC_BD, fs=7.4)
box(63, 68.6, 13.5, BH, "tile_result_collector", "16 结果串行输出", C_MAC_BD, fs=6.4)
box(79.5, 68.6, 13.5, BH, "collector index", "扫描下标直出", C_MAC_BD, fs=7.5)
box(79.5, 61.6, 13.5, BH, "collect_done",    "结果完成脉冲", C_MAC_BD, fs=7.0)

# ================= 连线(按接线总表 §7) =================
# --- CPU <-> mmio_if ---
wire([(9.7, 8.7), (13.0, 8.7)], C_CTRL, lw=1.9)
wlabel(11.3, 7.6, "MMIO", C_CTRL)
wire([(13.0, 10.3), (13.0, 12.3), (9.7, 12.3), (9.7, 9.35)], C_STAT)
wlabel(11.6, 13.0, "rdata/ready", C_STAT, fs=6.2)
# --- top 内部 ---
wire([(25.5, 8.7), (28.5, 8.7)], C_CTRL)
wire([(41.0, 8.7), (44.0, 8.7)], C_CTRL)
wire([(52.2, 11.0), (52.2, 14.2)], C_CTRL)
wire([(34.7, 11.0), (34.7, 14.2)], C_CTRL)
wire([(56.5, 8.7), (59.5, 8.7)], C_CTRL)
wire([(65.7, 11.0), (65.7, 14.2)], C_CTRL)
wire([(50.2, 16.5), (50.2, 19.2)], C_STAT, arrow=False)
wlabel(53.2, 20.0, "寄存器/Buffer 读数据 → mmio_if", C_STAT, fs=6.6, ha="left")
wire([(71.0, 16.5), (71.0, 19.6), (97.6, 19.6), (97.6, 27.8), (95.5, 27.8)], C_CTRL)
wlabel(85.0, 18.8, "CPU RAM 端口(core_busy=0 时放行)", C_CTRL, fs=6.8)
# --- start_ctrl -> tile_controller ---
wire([(63.5, 11.0), (63.5, 23.7), (10.7, 23.7), (10.7, 25.5)], C_CTRL, lw=1.8)
wlabel(37.5, 23.0, "start_pulse + M/N/K/TK/QUANT(锁存)", C_CTRL, fs=7.2)
# --- tile_controller 内部(红) ---
wire([(10.7, 31.2), (10.7, 32.3)], C_CTRL)                          # latch->checker
wire([(4.0, 28.1), (2.7, 28.1), (2.7, 41.4), (4.0, 41.4)], C_CTRL)  # latch->scheduler
wire([(17.5, 27.8), (20.5, 27.8)], C_CTRL)                          # latch->addr_gen
wire([(17.5, 34.6), (20.5, 34.6)], C_CTRL)                          # checker->fsm
wire([(10.7, 36.9), (10.7, 39.1)], C_CTRL)                          # scheduler->loop
wire([(17.5, 46.8), (19.4, 46.8), (19.4, 29.0), (20.5, 29.0)], C_CTRL)  # loop->addr_gen
wire([(17.5, 48.6), (20.5, 42.5)], C_CTRL)                          # loop->fsm
wire([(34.0, 33.9), (35.7, 33.9), (35.7, 28.9), (37.0, 28.9)], C_CTRL)  # fsm->a_stream
wire([(34.0, 34.8), (37.0, 34.8)], C_CTRL)                          # fsm->bt_stream
wire([(34.0, 39.4), (37.0, 41.4)], C_CTRL)                          # fsm->pair
wire([(31.9, 39.4), (31.9, 43.4), (43.7, 43.4), (43.7, 45.9)], C_CTRL)  # fsm->组合阵列控制
wire([(27.2, 42.5), (27.2, 45.9)], C_CTRL)                          # fsm->c_tile_acc
wire([(29.9, 42.5), (29.9, 52.3), (29.9, 52.3), (30.5, 52.3)], C_CTRL, alpha=0)  # 占位
wire([(20.5, 33.9), (18.9, 33.9), (18.9, 54.3), (20.5, 54.3)], C_CTRL)  # fsm->done_ctrl
# --- tile_controller 内部地址生成三色输出 ---
wire([(34.0, 27.8), (37.0, 27.8)], C_A)                             # -> a_stream
wlabel(35.5, 26.8, "A 基地址", C_A, fs=6.2)
wire([(27.2, 30.1), (27.2, 34.6), (37.0, 34.6)], C_BT)              # -> bt_stream
wlabel(31.0, 33.8, "BT 基地址", C_BT, fs=6.2)
wire([(33.5, 30.1), (33.5, 54.3), (37.0, 54.3)], C_C)               # -> c_write
wlabel(34.9, 44.0, "C 基地址", C_C, fs=6.2)
# --- A/BT 地址 -> buffer ---
wire([(43.7, 27.8), (58.7, 27.8), (58.7, 21.0), (66.0, 21.0), (66.0, 22.5)], C_A)
wlabel(51.0, 20.2, "a_addr / a_re", C_A, fs=6.4)
wire([(43.7, 34.6), (59.4, 34.6), (59.4, 20.6), (66.6, 20.6), (66.6, 22.5)], C_BT)
wlabel(52.5, 35.6, "bt_addr / bt_re", C_BT, fs=6.4)
# --- buffer 内部 ---
wire([(70.7, 30.1), (72.5, 30.1), (72.5, 32.3), (63.0, 32.3)], C_MIX)      # read_port 驱动 RAM
wlabel(75.4, 31.3, "读端口", C_MIX, fs=6.2, ha="left")
wire([(78.5, 27.8), (81.5, 27.8)], C_A)                                     # a_buf->fifo
wire([(78.5, 34.6), (81.5, 34.6)], C_BT)                                    # bt_buf->fifo
wire([(81.5, 41.4), (78.5, 41.4)], C_C)                                     # c_fifo->c_buf
wlabel(80.0, 40.3, "C 写", C_C, fs=6.2)
# FIFO -> pair_stream_ctrl
wire([(81.5, 27.8), (79.2, 27.8), (79.2, 37.2), (59.6, 37.2), (59.6, 40.4), (50.5, 40.4)], C_A)
wlabel(70.6, 36.4, "a_stream_data / valid", C_A, fs=6.6)
wire([(81.5, 34.6), (80.1, 34.6), (80.1, 44.6), (60.2, 44.6), (60.2, 41.8), (50.5, 41.8)], C_BT)
wlabel(70.6, 45.4, "bt_stream_data / valid", C_BT, fs=6.6)
# c_tile_write_ctrl -> c_write_fifo
wire([(50.5, 54.3), (57.4, 54.3), (57.4, 47.2), (97.2, 47.2), (97.2, 41.4)], C_C)
wlabel(77.0, 46.3, "cwr_valid / cwr_addr / cwr_data", C_C, fs=6.8)
# c_write_fifo -> done_ctrl
wire([(89.2, 41.4), (89.2, 55.6), (30.0, 55.6), (30.0, 56.7)], C_STAT, ls=(0, (3, 2)))
wlabel(60.0, 56.7, "c_wr_pulse(最后一笔真正写入才 core_done)", C_STAT, fs=6.6)
# --- ctrl -> mac 数据 ---
wire([(43.7, 41.4), (43.7, 56.6), (12.7, 56.6), (12.7, 61.6)], C_A)
wlabel(26.5, 55.8, "A 数据对(1 字 = 4 行 × 同一 k)", C_A, fs=6.6)
wire([(44.6, 41.4), (44.6, 57.4), (12.7, 57.4), (12.7, 58.6), (12.7, 68.6)], C_BT)
wlabel(26.5, 58.2, "BT 数据对(与 A 同拍成对推进)", C_BT, fs=6.6)
# tile_controller 阶段译码 -> mac
wire([(43.7, 50.5), (43.7, 60.2)], C_CTRL)
wire([(43.7, 60.2), (43.7, 59.8), (30.2, 59.8), (30.2, 61.6)], C_CTRL, ls=(0, (3, 2)))
wire([(69.7, 61.6), (69.7, 59.8), (50.7, 59.8), (50.7, 61.6)], C_CTRL, ls=(0, (3, 2)))
wlabel(45.4, 57.1, "array_start/enable/clear/flush", C_CTRL, fs=6.4, ha="left")
# --- mac 内部 ---
wire([(19.5, 63.9), (23.0, 63.9)], C_MIX)
wire([(19.5, 70.9), (23.0, 70.9)], C_MIX)
wire([(37.5, 66.0), (42.0, 66.0)], C_MIX, lw=1.8)
wlabel(39.8, 64.8, "波前", C_MIX, fs=6.6)
wire([(59.5, 67.4), (63.0, 67.4)], C_C)
wire([(69.7, 66.2), (69.7, 68.6)], C_CTRL)
wire([(76.5, 70.9), (79.5, 70.9)], C_C)
# collector -> c_tile_acc_ctrl
wire([(86.2, 68.6), (86.2, 53.6), (59.5, 53.6), (59.5, 48.2), (34.0, 48.2)], C_C)
wlabel(73.5, 52.7, "c_result / index / valid / last", C_C, fs=6.8)
# collect_done -> systolic_fsm
wire([(86.2, 61.6), (86.2, 59.2), (46.4, 59.2), (46.4, 40.6), (34.0, 40.6)], C_STAT, ls=(0, (3, 2)))
wlabel(66.5, 58.4, "collect_done", C_STAT, fs=6.6)
# --- 状态回传 ---
wire([(10.7, 52.0), (10.7, 21.0), (62.1, 21.0), (62.1, 11.0)], C_STAT)
wlabel(36.5, 20.3, "core_done", C_STAT, fs=7.2)
wire([(4.0, 34.6), (2.7, 34.6), (2.7, 16.5), (28.5, 16.5)], C_STAT, ls=(0, (3, 2)))
wlabel(9.0, 17.3, "status", C_STAT, fs=6.2)

# ---------- 图例 ----------
lx, ly = 3.5, 72.6
items = [(C_CTRL, "控制/调度/启动"), (C_A, "A 地址/数据"), (C_BT, "BT 地址/数据"),
         (C_C, "C 部分和/结果/写回"), (C_STAT, "busy/done/ready 状态"), (C_MIX, "A/BT 混合数据")]
ax.add_patch(FancyBboxPatch((lx, ly - 2.7), 41.0, 5.0,
    boxstyle="round,pad=0.15,rounding_size=0.4", fc="white", ec="#57606A", lw=1.1, zorder=5))
for i, (c, t) in enumerate(items):
    cx = lx + 1.4 + (i % 3) * 13.4
    cy = ly - 0.9 + (i // 3) * 1.9
    ax.plot([cx, cx + 2.0], [cy, cy], color=c, lw=2.2, zorder=6)
    ax.text(cx + 2.6, cy, t, fontsize=7.8, va="center", color=C_TXT, zorder=6)
ax.text(lx + 43.0, ly - 0.3,
        "底色:浅蓝 npu_top · 浅黄 tile_controller · 浅绿 npu_buffer · 浅紫 npu_mac\n"
        "通用底层模块:pe_cell · npu_ram · npu_sync_fifo · npu_stream_ctrl(被复用)\n"
        "RTL 全部通过 10 项仿真测试(Icarus Verilog 13, 含多 tile 累加/边界补零/量化/错误路径)",
        fontsize=7.8, va="top", color="#57606A", zorder=6, linespacing=1.6)

plt.subplots_adjust(left=0.004, right=0.996, top=0.996, bottom=0.004)
os.makedirs(OUT, exist_ok=True)
fig.savefig(os.path.join(OUT, "NPU_总体架构图.png"), dpi=200, facecolor="white")
fig.savefig(os.path.join(OUT, "NPU_总体架构图.svg"), facecolor="white")
print("OK")
