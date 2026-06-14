#!/usr/bin/env python3
"""Render the benchmark charts as grouped-bar images.

Mermaid's xychart-beta cannot draw grouped (side-by-side) bars or a
legend, so the README embeds these generated images instead.  Run this
after updating the numbers in the README tables:

    python3 bench/make-charts.py

Output PNGs go to .github/assets/.
"""
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import MaxNLocator

GPU = "#43b97f"
CAIRO = "#4f81e5"
COCOA = "#4f81e5"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", ".github", "assets")

WORKLOADS = ["Line scroll", "Page scroll", "Full redraw", "Typing", "Image scroll"]

# (filename, title, gpu values, cairo values, x-axis label)
PAIRED = [
    ("bench-linux-1616.png",
     "1616x912 frame: redisplays per second (higher is better)",
     [487, 296, 294, 1311, 1239],
     [530, 297, 247, 1857, 1359]),
    ("bench-linux-4k.png",
     "4K frame: redisplays per second (higher is better)",
     [240, 124, 121, 1766, 1328],
     [117, 102, 66, 238, 115]),
]


def paired_chart(fname, title, gpu, cairo):
    fig, ax = plt.subplots(figsize=(9, 4.5), dpi=140)
    y = range(len(WORKLOADS))
    h = 0.38
    # GPU on top of each pair, cairo just below.
    ax.barh([i + h / 2 for i in y], gpu, height=h, color=GPU, label="GPU (OpenGL)")
    ax.barh([i - h / 2 for i in y], cairo, height=h, color=CAIRO, label="Stock (cairo)")
    ax.set_yticks(list(y))
    ax.set_yticklabels(WORKLOADS)
    ax.invert_yaxis()
    ax.set_xlabel("redisplays per second")
    ax.set_title(title)
    ax.legend(loc="lower right", frameon=False)
    ax.spines[["top", "right"]].set_visible(False)
    top = max(max(gpu), max(cairo))
    ax.set_xlim(0, top * 1.12)
    for i in y:
        ax.text(gpu[i] + top * 0.01, i + h / 2, str(gpu[i]),
                va="center", ha="left", fontsize=8, color="#2a2a2a")
        ax.text(cairo[i] + top * 0.01, i - h / 2, str(cairo[i]),
                va="center", ha="left", fontsize=8, color="#2a2a2a")
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, fname), facecolor="white")
    plt.close(fig)
    print("wrote", fname)


def macos_chart():
    fname = "bench-macos-cpu.png"
    labels = ["Stock (Cocoa)", "GPU vsync on", "GPU vsync off"]
    vals = [16.0, 10.5, 15.5]
    colors = [COCOA, GPU, GPU]
    fig, ax = plt.subplots(figsize=(9, 3.0), dpi=140)
    y = range(len(labels))
    ax.barh(list(y), vals, height=0.5, color=colors)
    ax.set_yticks(list(y))
    ax.set_yticklabels(labels)
    ax.invert_yaxis()
    ax.set_xlabel("CPU seconds")
    ax.set_title("M1 Pro: CPU to render 15 s of flat-out scroll (lower is better)")
    ax.spines[["top", "right"]].set_visible(False)
    ax.set_xlim(0, max(vals) * 1.12)
    for i in y:
        ax.text(vals[i] + max(vals) * 0.01, i, f"{vals[i]:.1f} s",
                va="center", ha="left", fontsize=8, color="#2a2a2a")
    fig.tight_layout()
    fig.savefig(os.path.join(OUT, fname), facecolor="white")
    plt.close(fig)
    print("wrote", fname)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for args in PAIRED:
        paired_chart(*args)
    macos_chart()
