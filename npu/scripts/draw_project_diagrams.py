# -*- coding: utf-8 -*-
"""Draw the v2.1 RTL state and hardware diagrams used in the project report."""

from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Ellipse, FancyArrowPatch, Rectangle
from matplotlib.path import Path as MplPath


ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "figures"
OUT.mkdir(exist_ok=True)

plt.rcParams["font.family"] = "Noto Sans CJK SC"
plt.rcParams["svg.fonttype"] = "none"

INK = "#26313a"
MUTED = "#586772"
EDGE = "#53616c"
CONTROL = "#b6574c"
A = "#217e81"
BT = "#d27838"
RESULT = "#32815a"
BLUE = "#416eaa"
LIGHT_BLUE = "#eaf2f8"
LIGHT_ORANGE = "#fff1e5"
LIGHT_GREEN = "#e9f3ed"
LIGHT_TEAL = "#e6f3f1"
LIGHT_GRAY = "#f7f9fa"


def canvas(width, height):
    fig, ax = plt.subplots(figsize=(width / 150, height / 150), dpi=150)
    fig.patch.set_facecolor("white")
    ax.set_xlim(0, width)
    ax.set_ylim(height, 0)
    ax.axis("off")
    fig.subplots_adjust(0, 0, 1, 1)
    return fig, ax


def box(ax, x, y, w, h, title, detail="", fill="white", stroke=EDGE,
        title_size=16, detail_size=11, dashed=False):
    ax.add_patch(Rectangle((x, y), w, h, facecolor=fill, edgecolor=stroke,
                           linewidth=1.7, linestyle="--" if dashed else "-"))
    if detail:
        ax.text(x + w / 2, y + h / 2 - 12, title, ha="center", va="center",
                fontsize=title_size, fontweight="bold", color=INK)
        ax.text(x + w / 2, y + h / 2 + 17, detail, ha="center", va="center",
                fontsize=detail_size, color=MUTED)
    else:
        ax.text(x + w / 2, y + h / 2, title, ha="center", va="center",
                fontsize=title_size, fontweight="bold", color=INK)


def region(ax, x, y, w, h, title, color=EDGE):
    ax.add_patch(Rectangle((x, y), w, h, facecolor="none", edgecolor=color,
                           linewidth=1.5, linestyle=(0, (7, 5))))
    ax.text(x + 16, y - 11, title, fontsize=16, fontweight="bold", color=color,
            va="bottom", bbox=dict(facecolor="white", edgecolor="none", pad=3))


def line(ax, points, color=EDGE, width=1.7, dashed=False, arrow=True):
    xs, ys = zip(*points)
    ax.plot(xs, ys, color=color, linewidth=width,
            linestyle="--" if dashed else "-", solid_capstyle="round", zorder=2)
    if arrow:
        ax.add_patch(FancyArrowPatch(points[-2], points[-1], arrowstyle="-|>",
                                     mutation_scale=17, linewidth=width,
                                     color=color, zorder=3))


def curved_arrow(ax, start, control1, control2, end, color=EDGE, width=1.8):
    path = MplPath([start, control1, control2, end],
                   [MplPath.MOVETO, MplPath.CURVE4,
                    MplPath.CURVE4, MplPath.CURVE4])
    ax.add_patch(FancyArrowPatch(path=path, arrowstyle="-|>",
                                 mutation_scale=17, linewidth=width,
                                 color=color, zorder=2))


def label(ax, x, y, content, color=MUTED, size=11, align="center"):
    ax.text(x, y, content, color=color, fontsize=size, ha=align, va="center",
            bbox=dict(facecolor="white", edgecolor="none", pad=2), zorder=4)


def state(ax, x, y, name, description, fill=LIGHT_BLUE, width=190):
    ax.add_patch(Ellipse((x, y), width, 90, facecolor=fill,
                         edgecolor=EDGE, linewidth=1.8, zorder=3))
    ax.text(x, y - 10, name, ha="center", va="center", fontsize=13,
            fontweight="bold", color=INK, zorder=4)
    ax.text(x, y + 17, description, ha="center", va="center", fontsize=9,
            color=MUTED, zorder=4)


def hold_loop(ax, x, y):
    curve = MplPath([(x + 55, y + 30), (x + 145, y + 105),
                     (x + 150, y - 25), (x + 78, y - 16)],
                    [MplPath.MOVETO, MplPath.CURVE4,
                     MplPath.CURVE4, MplPath.CURVE4])
    ax.add_patch(FancyArrowPatch(path=curve, arrowstyle="-|>",
                                 mutation_scale=13, linewidth=1.2,
                                 color="#98a4aa", zorder=2))


def hold_loop_above(ax, x, y):
    curve = MplPath([(x - 55, y - 36), (x - 150, y - 150),
                     (x + 150, y - 150), (x + 55, y - 36)],
                    [MplPath.MOVETO, MplPath.CURVE4,
                     MplPath.CURVE4, MplPath.CURVE4])
    ax.add_patch(FancyArrowPatch(path=curve, arrowstyle="-|>",
                                 mutation_scale=13, linewidth=1.2,
                                 color="#98a4aa", zorder=2))


def draw_start_state_diagram():
    fig, ax = canvas(1500, 830)
    ax.text(750, 60, "NPU 启动控制状态图", ha="center", fontsize=26,
            fontweight="bold", color=INK)
    ax.text(750, 100, "start_ctrl：启动前校验、任务参数锁存、DONE / ERROR 状态",
            ha="center", fontsize=13, color=MUTED)
    region(ax, 80, 165, 1340, 555, "npu_top / start_ctrl", EDGE)

    print_fill = "#f8f9f9"
    state(ax, 300, 300, "ST_IDLE", "等待 start_req", print_fill)
    state(ax, 1000, 300, "ST_RUN", "运行中", print_fill)
    state(ax, 1000, 590, "ST_DONE", "DONE=1", print_fill)
    state(ax, 300, 590, "ST_ERROR", "ERROR=1", print_fill)

    ax.plot(35, 275, marker="o", markersize=5, color=EDGE, zorder=4)
    curved_arrow(ax, (35, 275), (100, 245), (175, 250), (235, 282))
    label(ax, 130, 240, "rst (同步)", INK, 11)

    curved_arrow(ax, (395, 300), (550, 278), (750, 278), (905, 300), width=2)
    label(ax, 650, 265, "start_req && cfg_ok", INK, 13)
    curved_arrow(ax, (1000, 345), (955, 400), (955, 490), (1000, 545), width=2)
    label(ax, 865, 445, "core_done", INK, 11)
    curved_arrow(ax, (1095, 590), (1350, 650), (1350, 240), (1095, 300))
    label(ax, 1295, 440, "start_req && cfg_ok", INK, 10)

    curved_arrow(ax, (300, 345), (255, 405), (255, 485), (300, 545), width=2)
    label(ax, 405, 440, "start_req && !cfg_ok", INK, 11)
    curved_arrow(ax, (205, 590), (85, 610), (85, 280), (205, 300))
    label(ax, 137, 445, "clear_done_req", INK, 11)
    curved_arrow(ax, (905, 590), (610, 615), (670, 385), (350, 340))
    label(ax, 620, 405, "!start_req && clear_done_req", INK, 10)
    curved_arrow(ax, (1000, 635), (1060, 705), (240, 705), (300, 635))
    label(ax, 650, 658, "start_req && !cfg_ok", INK, 11)
    hold_loop_above(ax, 1000, 300)
    hold_loop(ax, 300, 590)
    label(ax, 1270, 220, "其他条件保持", MUTED, 10)
    label(ax, 440, 543, "其他条件保持", MUTED, 10)

    ax.text(750, 758,
            "合法启动时锁存 M/N/K、TK、qshift、accumulate 并发出 start_pulse；ST_DONE 中 start_req 的优先级高于 clear_done_req。",
            ha="center", fontsize=12, color=MUTED)
    ax.text(750, 795, "灰色自环表示等待；ST_ERROR 需 clear_done_req 才能重新启动。",
            ha="center", fontsize=12, color=MUTED)
    save(fig, "NPU_启动状态图")


def draw_compute_state_diagram():
    fig, ax = canvas(1800, 1300)
    ax.text(900, 58, "NPU 计算控制状态图", ha="center", fontsize=26,
            fontweight="bold", color=INK)
    ax.text(900, 98, "systolic_fsm：输出 Tile 外循环、K Tile 内循环与结果写回等待",
            ha="center", fontsize=13, color=MUTED)
    region(ax, 70, 160, 1660, 765, "tile_controller / systolic_fsm", EDGE)

    state(ax, 200, 340, "S_IDLE", "等待启动")
    state(ax, 490, 340, "S_INIT", "初始化 Tile")
    state(ax, 790, 340, "S_CLEAR_ACC", "清 PE / 等写回", LIGHT_ORANGE, 225)
    state(ax, 1100, 340, "S_PREFETCH", "等待 A/BT FIFO", LIGHT_TEAL, 225)
    state(ax, 1550, 340, "S_FEED", "成对送数", LIGHT_TEAL)
    state(ax, 1550, 730, "S_DRAIN", "排空阵列", LIGHT_ORANGE)
    state(ax, 200, 730, "S_DONE", "等待 C 写回", LIGHT_GREEN)

    curved_arrow(ax, (295, 340), (325, 328), (365, 328), (395, 340), width=2)
    label(ax, 345, 306, "start_pulse", INK, 11)
    curved_arrow(ax, (585, 340), (610, 328), (650, 328), (677, 340), width=2)
    curved_arrow(ax, (903, 340), (925, 328), (965, 328), (987, 340), width=2)
    label(ax, 945, 305, "cwr_idle", INK, 11)
    curved_arrow(ax, (1213, 340), (1270, 320), (1390, 320), (1455, 340), width=2)
    label(ax, 1334, 305, "A/BT FIFO count ≥ valid_tk", INK, 11)

    curved_arrow(ax, (1550, 385), (1500, 470), (1500, 600), (1550, 685), width=2)
    label(ax, 1650, 532, "feed_beat_done && last_k_tile", INK, 10)
    curved_arrow(ax, (1455, 730), (1160, 790), (560, 790), (295, 730), width=2)
    label(ax, 875, 694, "drain_done && last_out_tile", INK, 11)
    curved_arrow(ax, (200, 685), (140, 595), (140, 475), (200, 385), width=2)
    label(ax, 305, 532, "core_done", INK, 11)

    curved_arrow(ax, (1550, 295), (1570, 200), (1090, 200), (1100, 295))
    label(ax, 1325, 203, "feed_beat_done && !last_k_tile", INK, 10)
    curved_arrow(ax, (1490, 697), (1330, 520), (840, 555), (790, 385))
    label(ax, 1085, 527, "drain_done && !last_out_tile", INK, 11)

    for x, y in ((790, 340), (1100, 340), (1550, 340),
                 (1550, 730), (200, 730)):
        hold_loop(ax, x, y)
    label(ax, 1195, 885, "灰色自环：等待条件尚未满足时保持状态", MUTED, 11)
    label(ax, 405, 885, "K Tile 间不清 PE；切换输出 Tile 时清 PE", MUTED, 11)

    ax.text(90, 975, "状态内动作 / 转移时脉冲", ha="left", fontsize=16,
            fontweight="bold", color=INK)
    rows = [
        ("S_INIT", "sched_init=1，tile_i / tile_j / tile_k 置零"),
        ("S_CLEAR_ACC", "acc_clear=1；cwr_idle 时发出 pf_start"),
        ("S_PREFETCH", "feed_cnt 置零；进入 FEED 时，若还有 K Tile 则发出 pf_next_start"),
        ("S_FEED", "feed_go=1；每次 pair_fire 计数；未到最后 K Tile 时发出 next_k_req"),
        ("S_DRAIN", "drain_en=1；drain_done 锁存快照；未到最后输出 Tile 时发出 next_out_req"),
        ("S_DONE", "fsm_done=1；等待 c_wr_pulse 计数达到 M×N 且写回通路空闲"),
    ]
    for i, (name, action) in enumerate(rows):
        y = 1010 + i * 39
        ax.plot([90, 1710], [y + 19, y + 19], color="#dce3e6", linewidth=1)
        ax.text(105, y, name, ha="left", va="center", fontsize=11,
                fontweight="bold", color=INK)
        ax.text(355, y, action, ha="left", va="center", fontsize=11, color=MUTED)
    ax.text(900, 1278, "全局输出：core_busy = (state != S_IDLE)；array_enable = feed_go || drain_en。",
            ha="center", fontsize=11, color=MUTED)
    save(fig, "NPU_状态图")


def draw_hardware_diagram():
    fig, ax = canvas(1800, 1080)
    ax.text(900, 54, "NPU v2.1 硬件框图", ha="center", fontsize=27,
            fontweight="bold", color=INK)
    ax.text(900, 95, "4×4 INT8 输出驻留式脉动阵列", ha="center",
            fontsize=13, color=MUTED)

    region(ax, 170, 155, 1580, 855, "npu_system", EDGE)
    box(ax, 25, 270, 115, 72, "CPU", fill=LIGHT_BLUE, stroke=BLUE)

    region(ax, 225, 215, 1340, 155, "npu_top", BLUE)
    box(ax, 260, 255, 175, 75, "ahb_lite_slave", fill=LIGHT_BLUE, stroke=BLUE, title_size=14)
    box(ax, 490, 255, 190, 75, "control_regs", fill=LIGHT_BLUE, stroke=BLUE, title_size=14)
    box(ax, 735, 255, 175, 75, "start_ctrl", fill=LIGHT_BLUE, stroke=BLUE, title_size=14)
    box(ax, 965, 255, 235, 75, "buffer_access_ctrl", fill=LIGHT_BLUE,
        stroke=BLUE, title_size=12)
    ax.text(1440, 293, "STATUS", ha="center", va="center",
            fontsize=13, color=BLUE)
    line(ax, [(140, 306), (205, 306), (205, 292), (260, 292)], BLUE, 2.2)
    label(ax, 195, 270, "MMIO", BLUE, 9)
    line(ax, [(435, 292), (490, 292)], BLUE)
    line(ax, [(680, 292), (735, 292)], BLUE)

    region(ax, 245, 440, 1320, 155, "tile_controller", CONTROL)
    box(ax, 290, 480, 280, 74, "systolic_fsm", fill=LIGHT_ORANGE,
        stroke=CONTROL, title_size=13)
    box(ax, 695, 480, 360, 74, "npu_stream_ctrl", "×2", LIGHT_ORANGE,
        CONTROL, title_size=12, detail_size=9)
    box(ax, 1270, 480, 260, 74, "c_tile_write_ctrl", "快照 / 量化", LIGHT_GREEN,
        RESULT, title_size=12, detail_size=9)
    line(ax, [(570, 517), (695, 517)], CONTROL)
    line(ax, [(820, 330), (820, 405), (430, 405), (430, 480)], CONTROL)
    label(ax, 620, 405, "start_pulse", CONTROL, 9)

    region(ax, 225, 690, 420, 255, "npu_buffer (A/BT)", A)
    box(ax, 260, 750, 150, 68, "A RAM", "64×32", LIGHT_TEAL, A,
        title_size=14, detail_size=10)
    box(ax, 260, 852, 150, 68, "BT RAM", "64×32", LIGHT_ORANGE, BT,
        title_size=14, detail_size=10)
    box(ax, 455, 750, 150, 68, "A FIFO", "64 字", LIGHT_TEAL, A,
        title_size=14, detail_size=10)
    box(ax, 455, 852, 150, 68, "BT FIFO", "64 字", LIGHT_ORANGE, BT,
        title_size=14, detail_size=10)
    line(ax, [(410, 784), (455, 784)], A, 2.4)
    line(ax, [(410, 886), (455, 886)], BT, 2.4)

    region(ax, 680, 690, 540, 255, "npu_mac", A)
    box(ax, 715, 770, 170, 110, "输入对齐", fill=LIGHT_TEAL,
        stroke=A, title_size=12)
    ax.add_patch(Rectangle((935, 728), 245, 195, facecolor=LIGHT_TEAL,
                           edgecolor=A, linewidth=1.8))
    ax.text(1058, 752, "pe_array", ha="center", fontsize=15,
            fontweight="bold", color=INK)
    for r in range(4):
        for c in range(4):
            box(ax, 960 + c * 55, 768 + r * 35, 42, 29, f"{r}{c}",
                fill="white", stroke=A, title_size=8)
    line(ax, [(605, 784), (665, 784), (665, 805), (715, 805)], A, 2.4)
    line(ax, [(605, 886), (665, 886), (665, 848), (715, 848)], BT, 2.4)
    line(ax, [(885, 825), (935, 825)], A, 2.4)

    region(ax, 1260, 690, 445, 255, "npu_buffer (C)", RESULT)
    box(ax, 1290, 788, 165, 80, "c_write_fifo", "32 字", LIGHT_GREEN,
        RESULT, title_size=12, detail_size=10)
    box(ax, 1500, 788, 165, 80, "C RAM", "256×32", LIGHT_GREEN,
        RESULT, title_size=14, detail_size=10)
    line(ax, [(1455, 828), (1500, 828)], RESULT, 2.4)
    line(ax, [(1180, 800), (1235, 800), (1235, 517), (1270, 517)], RESULT, 2.3)
    line(ax, [(1405, 554), (1405, 625), (1250, 625),
              (1250, 828), (1290, 828)], RESULT, 2.3)

    line(ax, [(875, 554), (875, 632), (335, 632), (335, 750)],
         CONTROL, 1.4, True)
    line(ax, [(430, 554), (430, 650), (1055, 650), (1055, 728)],
         CONTROL, 1.4, True)
    label(ax, 900, 982, "实线：数据流    虚线：控制    青色：A    橙色：BT    绿色：C", MUTED, 11)
    ax.text(900, 1040, "A/BT 每字各含 4 个 INT8；accumulate=1 时 c_write_fifo 对 C RAM 读改写。",
            ha="center", fontsize=11, color=MUTED)
    save(fig, "NPU_硬件框图")


def save(fig, stem):
    fig.savefig(OUT / f"{stem}.svg", facecolor="white")
    fig.savefig(OUT / f"{stem}.png", dpi=180, facecolor="white")
    plt.close(fig)
    print(OUT / f"{stem}.svg")
    print(OUT / f"{stem}.png")


if __name__ == "__main__":
    draw_start_state_diagram()
    draw_compute_state_diagram()
    draw_hardware_diagram()
