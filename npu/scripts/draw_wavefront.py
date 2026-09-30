# -*- coding: utf-8 -*-
# draw_wavefront.py — 4×4 脉动阵列数据流与波前对齐示意图 + 一个 K-tile 的时序
# 输出: ../figures/NPU_脉动阵列波前.png / .svg
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Rectangle, FancyArrowPatch
import os

plt.rcParams["font.sans-serif"] = ["Microsoft YaHei", "SimHei"]
plt.rcParams["axes.unicode_minus"] = False

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
OUT = os.path.join(PROJECT, "figures")
os.makedirs(OUT, exist_ok=True)

C_TXT   = "#1F2328"
C_A     = "#1F5FA8"
C_BT    = "#1E7D4F"
C_C     = "#D97706"
C_PE_BG = "#EDE7F8"
C_PE_BD = "#8F78BC"
C_WAVE  = "#FDE9C8"

fig = plt.figure(figsize=(19, 10.6), dpi=200)
gs = fig.add_gridspec(1, 2, width_ratios=[1.32, 1.0], wspace=0.04,
                      left=0.005, right=0.995, top=0.93, bottom=0.03)

# ===================== 左图:阵列与波前 =====================
ax = fig.add_subplot(gs[0, 0])
ax.set_xlim(0, 100)
ax.set_ylim(68, -7)
ax.set_autoscale_on(False)
ax.axis("off")
ax.text(50, -5.0, "4×4 脉动阵列:波前对齐(展示第 t=5 拍)", fontsize=15, weight="bold",
        color=C_TXT, ha="center", va="bottom")

gx, gy, cell = 30, 12, 10.5      # 阵列网格起点与单元尺寸
WAVE_T = 5                        # 高亮的当前拍

# 波前高亮:k + r + c = WAVE_T 的单元
for r in range(4):
    for c in range(4):
        k = WAVE_T - r - c
        on = 0 <= k
        fc = C_WAVE if on else C_PE_BG
        x0, y0 = gx + c*cell, gy + r*cell
        ax.add_patch(Rectangle((x0, y0), cell, cell, fc=fc, ec=C_PE_BD, lw=1.4, zorder=3))
        if on:
            ax.text(x0 + cell/2, y0 + cell/2 - 1.4, f"PE{r}{c}", fontsize=9.5, weight="bold",
                    ha="center", va="center", color="#5B4A87", zorder=4)
            ax.text(x0 + cell/2, y0 + cell/2 + 2.4, f"算 k={k}", fontsize=8.2,
                    ha="center", va="center", color="#9A6A00", zorder=4)
        else:
            ax.text(x0 + cell/2, y0 + cell/2, f"PE{r}{c}", fontsize=9.5, weight="bold",
                    ha="center", va="center", color="#8B7FB8", alpha=0.75, zorder=4)

# A 行输入(左侧)带 skew 延迟
for r in range(4):
    y = gy + r*cell + cell/2
    ax.annotate("", xy=(gx - 1.2, y), xytext=(gx - 9.5, y),
                arrowprops=dict(arrowstyle="-|>", color=C_A, lw=2.2, mutation_scale=16), zorder=4)
    ax.text(gx - 10.5, y, f"A 行{r}", fontsize=10.5, weight="bold", color=C_A,
            ha="right", va="center")
    if r > 0:
        for d in range(r):
            xc = gx - 3.0 - d*2.4
            ax.add_patch(Rectangle((xc - 0.95, y - 1.5), 1.9, 3.0, fc="white",
                                   ec=C_A, lw=1.1, zorder=4))
            ax.text(xc, y, "D", fontsize=6.8, ha="center", va="center", color=C_A, zorder=5)
ax.text(gx - 4.2, gy - 3.2, "skew:行 r 延迟 r 拍", fontsize=9.5, color=C_A, ha="center", weight="bold")

# BT 列输入(顶部)带 skew 延迟
for c in range(4):
    x = gx + c*cell + cell/2
    ax.annotate("", xy=(x, gy - 1.2), xytext=(x, gy - 9.5),
                arrowprops=dict(arrowstyle="-|>", color=C_BT, lw=2.2, mutation_scale=16), zorder=4)
    ax.text(x, gy - 10.6, f"BT 列{c}", fontsize=10.5, weight="bold", color=C_BT,
            ha="center", va="bottom" if False else "top")
    if c > 0:
        for d in range(c):
            yc = gy - 3.0 - d*2.4
            ax.add_patch(Rectangle((x - 1.5, yc - 0.95), 3.0, 1.9, fc="white",
                                   ec=C_BT, lw=1.1, zorder=4))
            ax.text(x, yc, "D", fontsize=6.8, ha="center", va="center", color=C_BT, zorder=5)
ax.text(gx - 6.5, gy - 7.6, "skew:列 c 延迟 c 拍", fontsize=9.5, color=C_BT,
        ha="right", weight="bold")

# 阵列内部传播箭头示例(行 0:向右)
for c in range(3):
    ax.annotate("", xy=(gx + (c+1)*cell + 0.6, gy + 0.5), xytext=(gx + c*cell + cell - 0.6, gy + 0.5),
                arrowprops=dict(arrowstyle="->", color=C_A, lw=1.0, alpha=0.55, mutation_scale=9), zorder=4)
for r in range(3):
    ax.annotate("", xy=(gx + cell - 1.2, gy + (r+1)*cell + 0.6), xytext=(gx + cell - 1.2, gy + r*cell + cell - 0.6),
                arrowprops=dict(arrowstyle="->", color=C_BT, lw=1.0, alpha=0.55, mutation_scale=9), zorder=4)

# 结果流出(右/下)
ax.annotate("", xy=(99, gy + 1.5*cell), xytext=(gx + 4*cell + 0.8, gy + 1.5*cell),
            arrowprops=dict(arrowstyle="-|>", color=C_C, lw=2.4, mutation_scale=17), zorder=4)
ax.text(97.5, gy + 1.5*cell - 2.6, "acc → 结果收集\n(排空后串行读出)", fontsize=9.5, color=C_C,
        ha="right", va="top", weight="bold")

# 说明框
ax.add_patch(FancyBboxPatch((2, 48.5), 96, 14.0,
    boxstyle="round,pad=0.4,rounding_size=0.8", fc="#F6F8FA", ec="#57606A", lw=1.2))
ax.text(4.5, 51.8,
        "对齐原理:A[r][k] 在拍 k+r 进入阵列左缘,向右每列 1 拍,于拍 k+r+c 到达 PE[r][c];\n"
        "BT[c][k] 在拍 k+c 进入阵列上缘,向下每行 1 拍,于拍 k+c+r 到达 PE[r][c]。\n"
        "两者恰好同拍相遇:每拍每 PE 恰好完成一次 acc += A[r][k]×BT[c][k](图中高亮为第 5 拍的波前对角线)。",
        fontsize=10.6, va="center", ha="left", color=C_TXT, linespacing=1.75)
ax.text(4.5, 60.8,
        "每个 PE 驻留一个 C 元素(输出驻留式):A 向右传播、BT 向下传播,valid 位随数据同步延迟;\n"
        "边界 tile 越界 lane 在 unpacker 侧补零,不产生越界 RAM 地址。",
        fontsize=9.6, va="center", ha="left", color="#57606A", linespacing=1.7)

# ===================== 右图:一个 K-tile 的时序 =====================
ax2 = fig.add_subplot(gs[0, 1])
ax2.set_xlim(0, 100)
ax2.set_ylim(68, -7)
ax2.set_autoscale_on(False)
ax2.axis("off")
ax2.text(50, -5.0, "一个 K-tile 的周期级时序(TK 拍喂数 + 6 拍排空)", fontsize=13.5, weight="bold",
         color=C_TXT, ha="center", va="bottom")

stages = [
    ("预取",   "PREFETCH\nA/BT 各 TK 字\n进预取 FIFO",          "#FFF3D6", "#B8964B"),
    ("启动",   "ARRAY_START\nPE 累加器清零",                     "#FDE4E1", "#C0392B"),
    ("喂数",   "ARRAY_FEED\nTK 拍, 每拍 1 对字\n= 4×4 路 MAC",   "#DCEAF8", "#1F5FA8"),
    ("排空",   "ARRAY_DRAIN\nP+Q-2 = 6 拍\n波前走完最远端",      "#E3F1E8", "#1E7D4F"),
    ("收结果", "16 拍串行输出\nacc[idx]/index/valid",            "#FDEBD7", "#D97706"),
    ("下一 tile", "tile_k+1 再累加\n或写回 C tile",              "#EFEBF8", "#8F78BC"),
]
x = 3.0
widths = [15, 12, 15, 13, 15, 15]
for (name, sub, fc, ec), w in zip(stages, widths):
    y0, h = 8.5, 13.5
    ax2.add_patch(FancyBboxPatch((x, y0), w, h,
        boxstyle="round,pad=0.15,rounding_size=0.5", fc=fc, ec=ec, lw=1.6, zorder=3))
    ax2.text(x + w/2, y0 + h/2 - 1.6, name, fontsize=11.5, weight="bold",
             ha="center", va="center", color=ec, zorder=4)
    ax2.text(x + w/2, y0 + h/2 + 2.8, sub, fontsize=7.8, ha="center", va="center",
             color="#424A53", zorder=4, linespacing=1.5)
    if x > 3.0:
        ax2.annotate("", xy=(x - 0.4, y0 + h/2), xytext=(x - 1.6, y0 + h/2),
                     arrowprops=dict(arrowstyle="-|>", color="#57606A", lw=1.6, mutation_scale=13))
    x += w + 2.0

# 时钟节拍标尺
ax2.annotate("", xy=(97.5, 26.5), xytext=(3.0, 26.5),
             arrowprops=dict(arrowstyle="-|>", color="#57606A", lw=1.3))
for i in range(11):
    xx = 3.0 + i * 9.45
    ax2.plot([xx, xx], [25.7, 26.5], color="#57606A", lw=1.0)
    ax2.text(xx, 28.0, str(i), fontsize=7.5, ha="center", color="#57606A")
ax2.text(50, 31.2, "时钟拍(enable 高时阵列推进;FIFO 空档自动等待)", fontsize=9.0,
         ha="center", color="#57606A")

# 三层循环示意
ax2.add_patch(FancyBboxPatch((6, 36.5), 88, 24.5,
    boxstyle="round,pad=0.4,rounding_size=0.8", fc="#F6F8FA", ec="#57606A", lw=1.2))
ax2.text(50, 39.6, "三层 tile 循环", fontsize=12.5, weight="bold", ha="center", color=C_TXT)
ax2.text(10.5, 44.5,
    "for tile_i  (行块, 步长 TM)\n"
    "  for tile_j  (列块, 步长 TN)\n"
    "    for tile_k  (K 方向, 步长 TK)\n"
    "      计算 4×4×TK 部分和 -> 留在 PE 累加器里连续累加",
    fontsize=9.6, va="top", ha="left",
    color="#24292F", linespacing=1.8)
ax2.text(63, 44.5,
    "· tile_k 之间不清累加器、不排空\n"
    "· 预取与喂数重叠，阵列在预取时冻结\n"
    "· 最后 tile_k 之后排空一次并整块快照\n"
    "· 写回与下一个输出 tile 的计算并行\n"
    "· 最后一笔 C 真正落 RAM → core_done",
    fontsize=9.6, va="top", ha="left", color="#424A53", linespacing=1.8)
ax2.text(50, 58.6, "16×16×16、TK=4 时共 4×4×4 = 64 个 tile,实测 3100 周期完成",
         fontsize=9.8, ha="center", color=C_C, weight="bold")

fig.suptitle("NPU 计算核心:脉动阵列数据流(与 RTL 实现一一对应)", fontsize=17,
             weight="bold", color=C_TXT, y=0.975)

os.makedirs(OUT, exist_ok=True)
fig.savefig(os.path.join(OUT, "NPU_脉动阵列波前.png"), dpi=200, facecolor="white")
fig.savefig(os.path.join(OUT, "NPU_脉动阵列波前.svg"), facecolor="white")
print("OK")
