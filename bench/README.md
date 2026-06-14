# Benchmark harness

Redisplay-throughput benchmarks: the GPU backend vs stock Emacs, on the **same binary** (GPU on vs off). These produce the tables in the top-level `README.md`.

## Requirements

- An Emacs built `--with-gpu` (point `EMACS` at it).
- `python3` with Pillow and numpy.
- `xvfb-run` (only for `run-bench-hires.sh`).

## Run (GNU/Linux, X11)

```sh
# On-screen, ~1616x912 frame on the current display:
EMACS=/path/to/gpu/emacs ./run-bench.sh [RUNS]

# Headless 4K render throughput (GPU renders to an FBO, no present):
EMACS=/path/to/gpu/emacs ./run-bench-hires.sh [RUNS]
```

Each prints a stock-vs-GPU fps table with the speedup ratio. `RUNS` defaults to 3; the median is reported.

## What it measures

Five workloads, each forcing `(redisplay t)` per frame (median of N runs, 80-frame warm-up first). GPU side runs vsync off (`GL_NO_VSYNC=1`) to measure frame cost, not the 60 Hz cap.

| Workload | Stresses |
|---|---|
| `line-scroll` | one line/frame: few new glyphs (cairo is strong here) |
| `page-scroll` | one window/frame: many new glyphs |
| `full-redraw` | `redraw-frame`: everything repainted |
| `typing` | one `self-insert`/frame: minimal dirty rect, floor is one buffer swap |
| `image-scroll` | scrolling images: cached texture re-composite vs cairo re-blit from CPU |

Buffer: 8000-line font-locked Emacs Lisp; image test uses a synthesized PNG.

Absolute numbers depend on GPU, driver and display server. The meaningful quantity is the **ratio** between the two modes on the same machine.

## Files

- `gl-bench.el` — the workloads. Reads `GL_MODE` (`gpu`/`vanilla`), `GL_BENCH_COLS`/`GL_BENCH_ROWS`, `GL_BENCH_OUT`. The scripts set these.
- `run-bench.sh` — on-screen comparison.
- `run-bench-hires.sh` — headless 4K render-throughput comparison.
- `make-charts.py` — regenerates the README chart images from the numbers (matplotlib).
