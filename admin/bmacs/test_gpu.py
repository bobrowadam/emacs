"""GPU presentation regression using only an isolated Bmacs process.

Set BMACS_PREPARED to a directory produced by manage.py prepare.  The test
maps a non-focusing window behind other windows, never using the normal
Emacs server.  A hidden frame or a nested Lisp sleep does not reproduce
top-level AppKit event-loop starvation; requests must come from outside.
"""

import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

import manage


@unittest.skipUnless(os.environ.get("BMACS_PREPARED"),
                     "set BMACS_PREPARED for isolated GPU presentation")
class PresentationResponsivenessTest(unittest.TestCase):
    def test_border_path_tracks_interior_stroke_pixels(self):
        """Run the renderer's actual perimeter function on Metal."""
        swift = shutil.which("swift")
        if not swift:
            self.skipTest("Swift is required for the Metal shader regression")
        source = (Path(__file__).resolve().parents[2] / "src/mtlterm.m").read_text()
        start = source.index("static float rounded_rect_path(")
        end = source.index("static float dash_along_distance(", start)
        shader = "#include <metal_stdlib>\nusing namespace metal;\n" + source[start:end]
        shader += """
kernel void check_path(device const float4 *samples [[buffer(0)]],
                       device float *results [[buffer(1)]],
                       uint i [[thread_position_in_grid]]) {
  results[i] = rounded_rect_path(samples[i].xy, float2(98, 38), samples[i].z);
}
"""
        samples = []
        for radius in (0, 0.25, 11):
            top, side = 98 - 2 * radius, 38 - 2 * radius
            quarter = math.pi * radius / 2
            perimeter = 2 * (top + side) + 4 * quarter
            # Both halves of a four-pixel stroke must follow the same edge.
            for offset in (-1.5, -0.5, 0.5, 1.5):
                for x in (20, 49, 78):
                    samples.append((x, offset, radius, (x - radius) / perimeter))
                samples.extend([
                    (98 + offset, 19, radius,
                     (top + quarter + 19 - radius) / perimeter),
                    (49, 38 + offset, radius,
                     (top + side + 2 * quarter + 49 - radius) / perimeter),
                    (offset, 19, radius,
                     (2 * top + side + 3 * quarter + 19 - radius) / perimeter),
                ])
        literals = ",\n".join("SIMD4<Float>(" + ", ".join(map(str, row)) + ")"
                               for row in samples)
        runner = """
import Foundation
import Metal
let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
guard let device = MTLCreateSystemDefaultDevice() else { exit(77) }
let library = try device.makeLibrary(source: source, options: nil)
let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "check_path")!)
let samples: [SIMD4<Float>] = [SAMPLES]
let input = samples.withUnsafeBytes {
  device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)!
}
let output = device.makeBuffer(length: samples.count * MemoryLayout<Float>.stride,
                               options: .storageModeShared)!
let command = device.makeCommandQueue()!.makeCommandBuffer()!
let encoder = command.makeComputeCommandEncoder()!
encoder.setComputePipelineState(pipeline)
encoder.setBuffer(input, offset: 0, index: 0)
encoder.setBuffer(output, offset: 0, index: 1)
encoder.dispatchThreads(MTLSize(width: samples.count, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
encoder.endEncoding()
command.commit()
command.waitUntilCompleted()
if let error = command.error { print(error); exit(1) }
let results = output.contents().bindMemory(to: Float.self, capacity: samples.count)
for i in samples.indices {
  if !results[i].isFinite || abs(results[i] - samples[i].w) > 0.00001 {
    print("Sample \\(samples[i]): got \\(results[i])")
    exit(1)
  }
}
print("Checked \\(samples.count) border perimeter samples on \\(device.name)")
""".replace("SAMPLES", literals)
        with tempfile.TemporaryDirectory(prefix="bmacs-border-path-", dir="/tmp") as temp:
            directory = Path(temp)
            (directory / "path.metal").write_text(shader)
            (directory / "check.swift").write_text(runner)
            result = subprocess.run([swift, str(directory / "check.swift"),
                                     str(directory / "path.metal")],
                                    capture_output=True, text=True, timeout=60)
        if result.returncode == 77:
            self.skipTest("No Metal device available")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        print(result.stdout.strip())

    def test_generic_compositor_pixels_and_animation_lifecycle(self):
        """Capture the actual compositor: shapes, clipping, z and final cleanup."""
        app = Path(os.environ["BMACS_PREPARED"]).expanduser().resolve() / "Bmacs.app"
        swift = shutil.which("swift")
        if not swift:
            self.skipTest("Swift is required to read compositor PNG pixels")
        stage = app.parent
        with tempfile.TemporaryDirectory(prefix="bmacs-decorations-", dir="/tmp") as temp:
            directory = Path(temp)
            socket = directory / "server"
            with (stage / "decoration-rendering.log").open("w") as log:
                process = subprocess.Popen(
                    [str(app / "Contents/MacOS/Emacs"), "-Q", f"--fg-daemon={socket}",
                     "--eval", f'(progn (setq user-emacs-directory "{temp}/") '
                     f'(startup-redirect-eln-cache "{temp}/eln-cache/"))'],
                    stdout=log, stderr=subprocess.STDOUT)
                try:
                    deadline = time.monotonic() + 30
                    while True:
                        self.assertIsNone(process.poll(), "Owned Bmacs exited")
                        try:
                            reply = manage.client(app, socket, "(emacs-pid)", timeout=1)
                            self.assertEqual(int(reply.stdout), process.pid)
                            break
                        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                            self.assertLess(time.monotonic(), deadline)
                            time.sleep(0.1)
                    manage.client(app, socket, """
(progn
  (require 'gpu)
  (gpu-animations nil)
  (setq decoration-test-frame
        (make-frame '((window-system . ns) (visibility . nil)
                      (no-accept-focus . t) (no-focus-on-map . t)
                      (z-group . below) (width . 60) (height . 22))))
  (gpu-enable-for-frame decoration-test-frame)
  (make-frame-visible decoration-test-frame)
  (lower-frame decoration-test-frame)
  (select-frame decoration-test-frame)
  (set-face-attribute 'default decoration-test-frame :background "#000000")
  (setq decoration-test-buffer (generate-new-buffer " decoration-test"))
  (set-window-buffer (frame-selected-window decoration-test-frame) decoration-test-buffer)
  (setq decoration-test-handles nil)
  (dolist (properties
           '((:rect (20 80 60 50) :radius 10 :fill 16711680 :stroke nil)
             (:rect (100 80 60 50) :fill 16711680 :stroke nil :z 10)
             (:rect (100 80 60 50) :fill 255 :stroke nil :z 0)
             (:shape circle :rect (180 80 50 50) :fill 65280 :stroke nil)
             (:shape arc :rect (250 80 50 50) :stroke 16777215 :stroke-width 4
                     :start-angle 0 :sweep-angle 1.57079632679)
             (:shape line :rect (20 170 60 40) :stroke 16711680 :stroke-width 4)
             (:shape line :rect (100 210 60 -40) :stroke 65280 :stroke-width 4)
             (:rect (180 170 60 40) :fill 255 :stroke nil :clip (180 170 30 40))
             (:shape arc :rect (180 270 40 40) :stroke 16777215 :stroke-width 4
                     :start-angle 0 :sweep-angle -1.57079632679)
             (:shape line :rect (20 250 40 0) :stroke 16711680 :stroke-width 4)
             (:shape line :rect (85 240 0 30) :stroke 65280 :stroke-width 4)
             (:shape line :rect (130 250 0 0) :stroke 255 :stroke-width 4)
             (:rect (250 200 30 30) :fill 16777215 :stroke nil :opacity 0.5)))
    (push (gpu-decoration-create properties decoration-test-frame decoration-test-buffer)
          decoration-test-handles))
  (unless (cl-every #'identity decoration-test-handles) (error "Rejected decoration"))
  t)
""", timeout=15)
                    time.sleep(0.2)
                    image = stage / "decoration-shapes.png"
                    reply = manage.client(app, socket,
                        f'(gpu-capture-frame "{image}" decoration-test-frame t)')
                    self.assertEqual(reply.stdout.strip(), "t")
                    # CoreGraphics decodes the PNG into known RGBA bytes.  Use
                    # logical frame size, not an assumed Retina scale.
                    width = int(manage.client(app, socket,
                        '(frame-pixel-width decoration-test-frame)').stdout)
                    height = int(manage.client(app, socket,
                        '(frame-pixel-height decoration-test-frame)').stdout)
                    samples = [
                        (50, 105, 255, 0, 0), (20, 80, 0, 0, 0),
                        (130, 105, 255, 0, 0),  # high z wins despite allocation order
                        (205, 105, 0, 255, 0), (180, 80, 0, 0, 0),
                        (300, 105, 255, 255, 255), (275, 130, 255, 255, 255),
                        (275, 80, 0, 0, 0), (250, 105, 0, 0, 0),
                        (275, 123, 0, 0, 0),  # no radial antialiasing fringe
                        (50, 190, 255, 0, 0), (130, 190, 0, 255, 0),
                        (195, 190, 0, 0, 255), (225, 190, 0, 0, 0),
                        (220, 290, 255, 255, 255), (200, 270, 255, 255, 255),
                        (200, 310, 0, 0, 0), (40, 250, 255, 0, 0),
                        (85, 255, 0, 255, 0), (130, 250, 0, 0, 255),
                        (265, 215, 128, 128, 128),
                    ]
                    literals = ",\n".join("[" + ",".join(map(str, row)) + "]" for row in samples)
                    reader = directory / "pixels.swift"
                    reader.write_text("""
import Foundation
import CoreGraphics
import ImageIO
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let w = image.width, h = image.height
var bytes = [UInt8](repeating: 0, count: w * h * 4)
bytes.withUnsafeMutableBytes { raw in
  let context = CGContext(data: raw.baseAddress, width: w, height: h,
    bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
}
let samples: [[Int]] = [SAMPLES]
for row in samples {
  let x = Int((Double(row[0]) + 0.5) * Double(w) / Double(WIDTH))
  let y = Int((Double(row[1]) + 0.5) * Double(h) / Double(HEIGHT))
  let offset = (y * w + x) * 4
  for c in 0..<3 {
    if abs(Int(bytes[offset + c]) - row[c + 2]) > 30 {
      print("Pixel \\(row): got \\(Array(bytes[offset..<offset+4]))")
      exit(1)
    }
  }
}
print("Checked \\(samples.count) compositor pixels")
""".replace("SAMPLES", literals).replace("WIDTH", str(width)).replace("HEIGHT", str(height)))
                    result = subprocess.run([swift, str(reader), str(image)],
                                            capture_output=True, text=True, timeout=60)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    print(result.stdout.strip())
                    # Create a fade, return to the top-level loop, and require
                    # native final opacity + track retirement without capture.
                    manage.client(app, socket, """
(progn
  (setq decoration-test-fade
        (gpu-decoration-create '(:rect (20 240 60 20) :fill 16777215 :stroke nil)
                               decoration-test-frame decoration-test-buffer))
  (gpu-decoration-animate decoration-test-fade :opacity 0 0.08 'ease-out))
""")
                    time.sleep(0.3)
                    reply = manage.client(app, socket, """
(let ((state (gpu--decoration-state (gpu--decoration-id decoration-test-fade)
                                     decoration-test-frame)))
  (unless (and (= (nth 1 state) 0) (not (nth 3 state)))
    (error "Terminal fade was not presented: %S" state))
  (unless (zerop (logand (gpu-pump-tick decoration-test-frame) 16))
    (error "Finished decoration still needs pumping"))
  ;; Hidden-frame time resumes, rather than restarting, after visibility returns.
  (gpu-decoration-update decoration-test-fade '(:opacity 1))
  (make-frame-invisible decoration-test-frame)
  (gpu-decoration-animate decoration-test-fade :opacity 0 0.05)
  t)
""")
                    self.assertEqual(reply.stdout.strip(), "t")
                    time.sleep(0.1)
                    manage.client(app, socket,
                        '(progn (make-frame-visible decoration-test-frame) (lower-frame decoration-test-frame))')
                    time.sleep(0.2)
                    reply = manage.client(app, socket, """
(let ((state (gpu--decoration-state (gpu--decoration-id decoration-test-fade)
                                     decoration-test-frame)))
  (unless (and (= (nth 1 state) 0) (not (nth 3 state)))
    (error "Hidden fade did not resume: %S" state))
  (kill-buffer decoration-test-buffer)
  (unless (cl-every (lambda (handle) (not (gpu--decoration-id handle)))
                    (cons decoration-test-fade decoration-test-handles))
    (error "Owned decorations survived buffer kill"))
  (delete-frame decoration-test-frame t)
  t)
""")
                    self.assertEqual(reply.stdout.strip(), "t")
                    manage.client(app, socket,
                                  '(run-at-time 0.1 nil (function kill-emacs))')
                    self.assertEqual(process.wait(timeout=10), 0)
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()

    def test_scrolling_does_not_copy_cursor_pixels(self):
        """Moving point while scrolling must not retain copies of the cursor."""
        app = Path(os.environ["BMACS_PREPARED"]).expanduser().resolve() / "Bmacs.app"
        swift = shutil.which("swiftc")
        if not swift:
            self.skipTest("Swift is required to read cursor PNG pixels")
        with tempfile.TemporaryDirectory(prefix="bmacs-cursor-", dir="/tmp") as temp:
            directory = Path(temp)
            socket = directory / "server"
            reader = directory / "pixels.swift"
            reader.write_text("""
import Foundation
import AppKit
for path in CommandLine.arguments.dropFirst() {
  let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: path)))!
  var red = 0
  for y in 0..<image.pixelsHigh {
    for x in 0..<image.pixelsWide {
      let c = image.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
      if c.redComponent > 0.7 && c.greenComponent < 0.3 && c.blueComponent < 0.3 {
        red += 1
      }
    }
  }
  print(red)
}
""")
            counter = directory / "pixels"
            subprocess.run([swift, str(reader), "-o", str(counter)], check=True,
                           capture_output=True, text=True, timeout=60)
            with (app.parent / "cursor-rendering.log").open("w") as log:
                process = subprocess.Popen(
                    [str(app / "Contents/MacOS/Emacs"), "-Q", f"--fg-daemon={socket}",
                     "--eval", f'(progn (setq user-emacs-directory "{temp}/" '
                     'native-comp-jit-compilation nil) '
                     f'(startup-redirect-eln-cache "{temp}/eln-cache/"))'],
                    stdout=log, stderr=subprocess.STDOUT)

                def client(code):
                    return manage.client(app, socket, code, timeout=10).stdout

                def selected(code):
                    return client("(with-selected-window (frame-selected-window "
                                  "cursor-test-frame) " + code + ")")

                def capture(name):
                    # Return to the top-level event loop before reading pixels.
                    time.sleep(0.1)
                    path = app.parent / ("cursor-" + name + ".png")
                    client(f"(gpu-capture-frame {json.dumps(str(path))} cursor-test-frame t)")
                    return path

                try:
                    deadline = time.monotonic() + 30
                    while True:
                        self.assertIsNone(process.poll(), "Owned Bmacs exited")
                        try:
                            reply = manage.client(app, socket, "(emacs-pid)", timeout=1)
                            self.assertEqual(int(reply.stdout), process.pid)
                            break
                        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                            self.assertLess(time.monotonic(), deadline)
                            time.sleep(0.1)
                    client("""
(progn
  (require 'gpu)
  (blink-cursor-mode -1)
  (setq cursor-test-frame
        (make-frame '((window-system . ns) (visibility . nil)
                      (no-accept-focus . t) (no-focus-on-map . t) (z-group . below)
                      (width . 60) (height . 28) (tool-bar-lines . 0))))
  (set-face-attribute 'default cursor-test-frame :background "#202020" :foreground "#dddddd")
  (set-frame-parameter cursor-test-frame 'cursor-color "#ff0000")
  (gpu-enable-for-frame cursor-test-frame)
  (make-frame-visible cursor-test-frame)
  (lower-frame cursor-test-frame)
  (select-frame cursor-test-frame)
  (switch-to-buffer (generate-new-buffer " cursor-test"))
  (setq-local mode-line-format nil scroll-conservatively 101 scroll-margin 0)
  (dotimes (n 120) (insert (format "Line %03d: ordinary text without decorations\\n" n)))
  t)
""")
                    for animations in (False, True):
                        client(f"(gpu-animations {'t' if animations else 'nil'})")
                        for shape in ("box", "hollow", "bar", "hbar"):
                            for direction in (1, -1):
                                name = f"{shape}-{int(animations)}-{direction}"
                                with self.subTest(shape=shape, animations=animations,
                                                  direction=direction):
                                    selected(f"""(progn
  (setq-local cursor-type '{shape} cursor-in-non-selected-windows '{shape})
  (goto-char (point-min)) (forward-line 20)
  (set-window-start (selected-window) (save-excursion (forward-line -12) (point)))
  (redraw-frame cursor-test-frame) (redisplay t) t)""")
                                    initial = capture(name + "-initial")
                                    for _ in range(8):
                                        # Redisplay sees scroll and point motion together.
                                        selected(f"(progn (scroll-up {direction}) "
                                                 f"(forward-line {direction}) (redisplay t) t)")
                                    selected("(progn (setq-local cursor-type nil) (redisplay t) t)")
                                    hidden = capture(name + "-hidden")
                                    counts = subprocess.run(
                                        [str(counter), str(initial), str(hidden)],
                                        check=True, capture_output=True, text=True, timeout=15)
                                    before, after = map(int, counts.stdout.split())
                                    self.assertGreater(before, 0, "Test did not paint a red cursor")
                                    self.assertEqual(after, 0, f"Stale cursor pixels in {hidden}")
                    client("(run-at-time 0.1 nil (function kill-emacs))")
                    self.assertEqual(process.wait(timeout=10), 0)
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=10)

    def test_animation_does_not_starve_server(self):
        app = Path(os.environ["BMACS_PREPARED"]).expanduser().resolve() / "Bmacs.app"
        with tempfile.TemporaryDirectory(prefix="bmacs-gpu-", dir="/tmp") as temp:
            directory = Path(temp)
            socket = directory / "server"
            log_path = directory / "daemon.log"
            with log_path.open("w") as log:
                process = subprocess.Popen(
                    [str(app / "Contents/MacOS/Emacs"), "-Q", f"--fg-daemon={socket}",
                     "--eval", f'(progn (setq user-emacs-directory "{temp}/") '
                     f'(startup-redirect-eln-cache "{temp}/eln-cache/"))'],
                    env=os.environ | {"MTL_LOG_SEQ": "1"},
                    stdout=log, stderr=subprocess.STDOUT)
                try:
                    deadline = time.monotonic() + 30
                    while True:
                        self.assertIsNone(process.poll(), "Isolated Bmacs exited")
                        try:
                            reply = manage.client(app, socket, "(emacs-pid)", timeout=1)
                            self.assertEqual(int(reply.stdout), process.pid)
                            break
                        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                            self.assertLess(time.monotonic(), deadline, "Bmacs did not start")
                            time.sleep(0.1)
                    # Start both native and Lisp animation clocks, then return
                    # to the top-level event loop before sending more requests.
                    manage.client(app, socket, """
(progn
  (setq gpu-test-frame
        (make-frame '((window-system . ns) (visibility . nil)
                      (no-accept-focus . t) (no-focus-on-map . t)
                      (z-group . below) (width . 40) (height . 12))))
  (gpu-animations t)
  (gpu-enable-for-frame gpu-test-frame)
  (make-frame-visible gpu-test-frame)
  (lower-frame gpu-test-frame)
  (select-frame gpu-test-frame)
  (unless (gpu-transition-start 60.0 gpu-test-frame)
    (error "No GPU texture: test would not present"))
  (require 'gpu)
  (setq gpu-test-decoration
        (gpu-decoration-create '(:rect (10 10 100 40) :stroke 16777215) gpu-test-frame))
  (gpu-decoration-animate gpu-test-decoration :opacity 0.2 1 'ease-in-out t)
  (run-at-time 0.033 0.033 #'gpu-pump-tick gpu-test-frame))
""", timeout=10)
                    latencies = []
                    for _ in range(10):
                        # Let the display link run between independent requests.
                        time.sleep(0.05)
                        start = time.monotonic()
                        reply = manage.client(app, socket, "(emacs-pid)", timeout=2)
                        latencies.append(time.monotonic() - start)
                        self.assertEqual(int(reply.stdout), process.pid)
                    # Responsiveness must not be achieved by dropping all frames.
                    self.assertGreaterEqual(log_path.read_text().count("] PRESENT "), 5)
                    print(f"GPU server latency: max {max(latencies) * 1000:.1f} ms")
                    manage.client(app, socket,
                                  "(run-at-time 0.1 nil (function kill-emacs))", timeout=2)
                    self.assertEqual(process.wait(timeout=10), 0)
                finally:
                    # Terminate only the subprocess created by this test.
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()


if __name__ == "__main__":
    unittest.main()
