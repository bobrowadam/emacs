#!/usr/bin/env bash
# High-resolution render-throughput benchmark: does the GPU scale better
# than cairo as the pixel count grows?
#
# Runs both modes headless under a 4K Xvfb screen.  The GPU side uses
# GL_FORCE_SURFACELESS (real GPU, render to an FBO, no on-screen present);
# the stock side is cairo on the CPU.  This isolates per-frame *rendering*
# cost at a large pixel count -- the GPU side skips present, so it is a
# rendering-throughput comparison, not an on-screen one.
#
# Usage:
#   EMACS=/path/to/gpu/emacs ./run-bench-hires.sh [RUNS]
#
#   EMACS            path to an emacs built --with-gpu (default "emacs").
#   RUNS             repetitions; median reported (default 3).
#   GL_BENCH_COLS    frame width in columns  (default 470, ~3760 px).
#   GL_BENCH_ROWS    frame height in rows    (default 130, ~2210 px).
#   GL_SCREEN        Xvfb screen geometry    (default 3840x2160x24).
#
# Requires xvfb-run and python3 with Pillow and numpy.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMACS="${EMACS:-emacs}"
EL="$SCRIPT_DIR/gl-bench.el"
RUNS="${1:-3}"
COLS="${GL_BENCH_COLS:-470}"
ROWS="${GL_BENCH_ROWS:-130}"
SCREEN="${GL_SCREEN:-3840x2160x24}"

OUT="$(mktemp -d)"
export GL_BENCH_OUT="$OUT"
trap 'rm -rf "$OUT"' EXIT

python3 - "$OUT/bench-img.png" <<'PY'
import sys
from PIL import Image
import numpy as np
w, h = 240, 160
x = np.linspace(0, 1, w); y = np.linspace(0, 1, h); xx, yy = np.meshgrid(x, y)
r = (128 + 127 * np.sin(xx * 12)).astype('uint8')
g = (128 + 127 * np.sin(yy * 12 + 1)).astype('uint8')
b = (128 + 127 * np.sin((xx + yy) * 9 + 2)).astype('uint8')
Image.fromarray(np.dstack([r, g, b])).save(sys.argv[1])
PY

for i in $(seq 1 "$RUNS"); do
  echo "run $i / $RUNS ..."
  GL_MODE=gpu GL_FORCE_SURFACELESS=1 GL_NO_VSYNC=1 \
    GL_BENCH_COLS=$COLS GL_BENCH_ROWS=$ROWS GL_BENCH_OUT="$OUT" \
    xvfb-run -a -s "-screen 0 $SCREEN" "$EMACS" -Q -l "$EL"
  GL_MODE=vanilla EMACS_GPU_DISABLE=1 \
    GL_BENCH_COLS=$COLS GL_BENCH_ROWS=$ROWS GL_BENCH_OUT="$OUT" \
    xvfb-run -a -s "-screen 0 $SCREEN" "$EMACS" -Q -l "$EL"
done

python3 - "$OUT" <<'PY'
import re, sys, statistics as st, os
out = sys.argv[1]
def parse(p):
    d = {}
    for line in open(p):
        m = re.match(r"(\S+) frames=(\d+) sec=([\d.]+) fps=([\d.]+)", line)
        if m:
            d.setdefault(m.group(1), []).append(float(m.group(4)))
    return {k: st.median(v) for k, v in d.items()}
g = parse(os.path.join(out, "gl-bench-gpu.txt"))
v = parse(os.path.join(out, "gl-bench-vanilla.txt"))
print("\n4K render throughput (GPU render-to-FBO vs cairo CPU)")
print(f"{'workload':14s} {'cairo fps':>10s} {'gpu fps':>9s} {'speedup':>9s}")
print("-" * 46)
for k in ["line-scroll", "page-scroll", "full-redraw", "typing", "image-scroll"]:
    if k in g and k in v:
        sp = g[k] / v[k] if v[k] else 0
        print(f"{k:14s} {v[k]:10.1f} {g[k]:9.1f} {sp:8.2f}x")
PY
