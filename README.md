# emacs-gpu

GNU Emacs with a GPU-accelerated display backend.

On **macOS** it renders with **native Apple Metal**: text goes through a
GPU glyph atlas, images and inline video are textures, and the whole
frame is composited by the GPU instead of CoreGraphics. The output is
pixel-accurate against the stock Cocoa backend.

**OpenGL support for GNU/Linux and Windows is planned but not implemented
yet.** The drawing logic is already platform-neutral (`src/gfxterm.c`)
behind a small driver interface (`src/gfxdrv.h`); an OpenGL driver only
needs to implement that interface (`src/glterm.c` is the documented
skeleton). Contributions welcome.

## Why a GPU backend?

Beyond raw rendering, it enables things the stock backend cannot do:

- **Video playback**: AVFoundation decodes straight into Metal textures
  (zero copies) and the frames are composited inside the buffer,
  following scrolling and clipped to the window. No xwidgets, no
  embedded browser. Opening a video file (for example with `RET` in
  Dired) plays it in a dedicated buffer with autoplay, looping, and a
  clickable play/pause and timeline. Video can also be embedded inline
  at point.
- **GPU cursor effects** (opt-in): expanding rings, comet trails and
  friends are drawn as a compositor overlay, without ever touching the
  buffer content underneath.
- **A path to cheap visual effects**: buffer transitions, smooth
  scrolling or any future eye candy is one more shader pass over the
  composited frame, not a rewrite of the display engine.

Text is rasterized once into a GPU glyph atlas and drawn as textured
quads; scrolling moves already-rendered pixels with a texture blit.

## Performance

Measured on an Apple M1 Pro (Emacs 32 development build, 120x45 frame,
font-locked `xdisp.c`, same binary with and without the GPU backend;
`/usr/bin/time -l` over scripted workloads):

| Workload | Stock (Cocoa) | GPU, vsync on (default) | GPU, vsync off |
|---|---|---|---|
| Sustained scroll, redisplays/s | 481 | 324 | 475 |
| CPU for 15 s of that scroll | 16.0 s | **10.5 s** | 15.5 s |
| Typing throughput (chars/s, machine-paced) | 108 | 52 | 106 |
| Idle (8 s) CPU | 1.21 s | 1.19 s | same |
| Peak RSS | ~140 MB | ~144 MB | same |

Honest reading:

- **Machine-paced throughput and CPU cost match the stock backend**
  (vsync off). There is no GPU tax.
- With vsync on (the default), presents wait for the display refresh:
  the screen shows the same 60 fps either way, but Emacs burns ~35%
  less CPU under flat-out scrolling because it stops rendering frames
  nobody can see. Human-paced input is unaffected (the cap is ~52
  machine-paced updates/s; keyboard auto-repeat tops out well below
  that). `(gpu-vsync nil)` switches to uncapped, stock-like behavior.
- Idle cost is identical and the GPU resources add ~4 MB of RSS.

> Status: experimental, under active development.
>
> **Note:** I am not answering issues for now. Feel free to open them as
> a public record (they will be read eventually), but do not expect a
> reply at this stage.

## Demos

Inline video playing inside a buffer, decoded by AVFoundation straight
into Metal textures (`gpu-video-insert`):

![Inline video](.github/assets/inline-video.gif)

An animated GIF playing next to font-locked code scrolling, all
composited by the GPU:

![Animated GIF and code](.github/assets/gif-and-code.gif)

GPU cursor effects (`gpu-animations`), here the *sonicboom* mode:

![Sonicboom cursor](.github/assets/cursor-sonicboom.gif)

Buffer switches cross-fade on the GPU (on by default, configurable):

![Buffer cross-fade](.github/assets/buffer-crossfade.gif)

## Installing

With Homebrew (Apple Silicon, macOS 13 Ventura or newer):

```sh
brew install --cask tanrax/tap/emacs-gpu
```

Or grab the signed, self-contained `Emacs.app` from the
[releases](https://github.com/tanrax/emacs-gpu/releases). The release
build ships with native compilation (AOT) and tree-sitter enabled.

## Building on macOS

Requires Xcode (or the Command Line Tools) and the usual Emacs build
dependencies (`brew install autoconf automake gnutls texinfo pkg-config`).

```sh
./autogen.sh

SDK=$(xcrun --sdk macosx --show-sdk-path)
CC="xcrun clang" OBJC="xcrun clang" \
CFLAGS="-isysroot $SDK" CPPFLAGS="-isysroot $SDK" OBJCFLAGS="-isysroot $SDK" \
./configure --with-ns --with-mtl

make -j$(sysctl -n hw.ncpu)
```

The binary is `src/emacs` (or install the app bundle from `nextstep/`).

## Enabling the GPU backend

When Emacs is built `--with-mtl` and Metal is available, the GPU backend
is loaded and enabled automatically on the initial frame at startup. This
applies to both the release app bundle and source builds. To start with
the stock Cocoa backend instead, set the environment variable
`EMACS_GPU_DISABLE` to any non-empty value:

```sh
EMACS_GPU_DISABLE=1 emacs
```

You can also enable it manually on a given frame (for example after
starting with it disabled):

```elisp
(require 'gpu)
(gpu-enable)
```

## Commands and options

| Command | What it does |
|---|---|
| `M-x gpu-status` | Show backend state: GPU device, animations, cursor mode |
| `M-: (gpu-draw-stats)` | Renderer counters; `glyphs-drawn` growing proves the GPU is painting |
| `M-x gpu-toggle-animations` | Toggle the GPU compositor overlay used by cursor effects |
| `M-x gpu-set-cursor` | Pick the cursor effect: `block` (static, default, no effect), `sonicboom` (ring), `torpedo` (comet trail), `spring`, `ripple`, `pixiedust`, `hollow`, `beam` |
| `M-: (gpu-vsync nil)` | Uncap presents from the display refresh (lower latency, more power) |
| `M-: (gpu-video-insert "clip.mp4" 480 270 t)` | Play a video inline at point; follows scrolling |
| `M-x gpu-video-stop` | Stop the inline video |

### Playing video files

Visiting a video file (`mp4`, `mov`, `m4v`, `3gp`) opens it in
`gpu-video-mode`: a dedicated buffer that autoplays and loops the video,
fit to the window, with a play/pause button and a clickable, draggable
timeline. From Dired just press `RET` on the file.

| Key | Action |
|---|---|
| `SPC` | Play / pause |
| `←` / `→` | Seek backward / forward by `gpu-video-seek-step` seconds (default 5) |
| `<` | Seek to the start |
| `mouse-1` on the timeline | Jump to that point (drag to scrub) |

Customize the recognized extensions with `gpu-video-file-extensions`
(then run `M-x gpu-video-register-auto-mode`). Animated GIFs keep using
the built-in `image-mode`, which already animates them on the GPU.

Cursor effects are opt-in. Pick one interactively with
`M-x gpu-set-cursor`, or set it in your init file. For example, to
enable the *sonicboom* effect (an expanding ring on cursor jumps):

```elisp
;; `gpu' is loaded at startup, so defer until it is available.
(with-eval-after-load 'gpu
  (setopt gpu-cursor-animation 'sonicboom))
```

Other modes: `block` (default, no effect), `torpedo` (comet trail),
`spring`, `ripple`, `pixiedust`, `hollow`, `beam`.

Cursor effects trigger on cursor jumps (`M-<`, `M->`, isearch hits),
not on single-character movement. They are also suppressed while
typing or editing text, so they fire only when you move the cursor,
not on every inserted or deleted character. To get the effects while
typing too:

```elisp
(setq gpu-cursor-effects-while-typing t)
```

Buffer switches cross-fade by default; tune or disable with:

```elisp
(setq gpu-buffer-transition-duration 0.15) ; seconds
(setq gpu-buffer-transitions nil)          ; turn it off
```

## How it works

```
redisplay engine (xdisp.c, untouched)
        ↓
src/gfxterm.c   platform-neutral drawing policy
        ↓
src/gfxdrv.h    driver interface (~25 ops)
        ↓
src/mtlterm.m   Metal driver: glyph atlas (CoreText → R8 texture),
                render cycle on a persistent texture, AVFoundation
                video through CVMetalTextureCache
```

## License

GNU General Public License v3 or later, same as GNU Emacs.
