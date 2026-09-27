"""GPU presentation regression using only an isolated Bmacs process.

Set BMACS_PREPARED to a directory produced by manage.py prepare.  The test
maps a non-focusing window behind other windows, never using the normal
Emacs server.  A hidden frame or a nested Lisp sleep does not reproduce
top-level AppKit event-loop starvation; requests must come from outside.
"""

import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

import manage


@unittest.skipUnless(os.environ.get("BMACS_PREPARED"),
                     "set BMACS_PREPARED for isolated GPU presentation")
class PresentationResponsivenessTest(unittest.TestCase):
    def test_animation_does_not_starve_server(self):
        app = Path(os.environ["BMACS_PREPARED"]).expanduser().resolve() / "Bmacs.app"
        with tempfile.TemporaryDirectory(prefix="bmacs-gpu-", dir="/tmp") as temp:
            directory = Path(temp)
            socket = directory / "server"
            log_path = directory / "daemon.log"
            with log_path.open("w") as log:
                process = subprocess.Popen(
                    [str(app / "Contents/MacOS/Emacs"), "-Q", f"--fg-daemon={socket}"],
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
