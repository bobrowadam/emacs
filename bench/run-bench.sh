#!/usr/bin/env bash
# Redisplay throughput benchmark: stock (X/cairo) vs GPU (OpenGL/EGL).
#
# Runs on a real X display so the GPU path hits the real GPU; vsync is
# turned off on the GPU side (GL_NO_VSYNC=1) so we measure frame cost,
# not the 60 Hz refresh cap.  Both sides use the SAME binary: the GPU
# side calls gpu-enable-for-frame, the stock side sets EMACS_GPU_DISABLE.
#
# Usage:
#   EMACS=/path/to/gpu/emacs ./run-bench.sh [RUNS]
#
#   EMACS   path to an emacs built --with-gpu (default: "emacs" on PATH).
#   RUNS    number of repetitions; the median is reported (default 3).
#   DISPLAY the X display to use (default :0).
#
# Requires python3 with Pillow and numpy (to synthesize the test image).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMACS="${EMACS:-emacs}"
EL="$SCRIPT_DIR/gl-bench.el"
RUNS="${1:-3}"

export DISPLAY="${DISPLAY:-:0}"
OUT="$(mktemp -d)"
export GL_BENCH_OUT="$OUT"
trap 'rm -rf "$OUT"' EXIT

# A photo-like image so decode+upload is non-trivial (favors the GPU).
python3 - "$OUT/bench-img.png" <<'PY'
import sys
from PIL import Image
import numpy as np
w, h = 240, 160
x = np.linspace(0, 1, w); y = np.linspace(0, 1, h)
xx, yy = np.meshgrid(x, y)
r = (128 + 127 * np.sin(xx * 12)).astype('uint8')
g = (128 + 127 * np.sin(yy * 12 + 1)).astype('uint8')
b = (128 + 127 * np.sin((xx + yy) * 9 + 2)).astype('uint8')
Image.fromarray(np.dstack([r, g, b])).save(sys.argv[1])
print("bench-img.png ready")
PY

for i in $(seq 1 "$RUNS"); do
  echo "run $i / $RUNS ..."
  GL_MODE=gpu     GL_NO_VSYNC=1      "$EMACS" -Q -l "$EL"
  GL_MODE=vanilla EMACS_GPU_DISABLE=1 "$EMACS" -Q -l "$EL"
done

echo "=== raw gpu ===";     cat "$OUT/gl-bench-gpu.txt"
echo "=== raw vanilla ==="; cat "$OUT/gl-bench-vanilla.txt"

python3 - "$OUT" <<'PY'
import re, sys, statistics as st, os
out = sys.argv[1]
def parse(path):
    d = {}
    for line in open(path):
        m = re.match(r"(\S+) frames=(\d+) sec=([\d.]+) fps=([\d.]+) ms=([\d.]+)", line)
        if m:
            d.setdefault(m.group(1), []).append(float(m.group(4)))
    return {k: st.median(v) for k, v in d.items()}
g = parse(os.path.join(out, "gl-bench-gpu.txt"))
v = parse(os.path.join(out, "gl-bench-vanilla.txt"))
order = ["line-scroll", "page-scroll", "full-redraw", "typing", "image-scroll"]
print(f"\n{'benchmark':14s} {'vanilla fps':>12s} {'gpu fps':>10s} {'speedup':>9s}")
print("-" * 48)
for k in order:
    if k in g and k in v:
        sp = g[k] / v[k] if v[k] else 0
        print(f"{k:14s} {v[k]:12.1f} {g[k]:10.1f} {sp:8.2f}x")
PY
