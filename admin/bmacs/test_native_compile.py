"""Exercise native workers only in disposable batch Emacs processes."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import manage


@unittest.skipUnless(sys.platform == "darwin"
                     and (manage.APP / "Contents/MacOS/Emacs").exists(),
                     "requires installed Bmacs; never replaces it")
class NativeWorkerTests(unittest.TestCase):
    def run_worker(self, compile_source):
        temp = tempfile.TemporaryDirectory(prefix="bmacs-native-test-")
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        source = root / "fixture.el"
        source.write_text(";;; -*- lexical-binding: t; -*-\n"
                          "(defun bmacs-native-test-fixture (n) (1+ n))\n")
        cache = root / "cache"
        cache.mkdir()
        file = json.dumps(str(source))
        action = f"(native-compile-async (list {file}))" if compile_source else "nil"
        setup = (
            f"(progn (require 'comp) (byte-compile-file {file}) "
            f"(setq native-comp-eln-load-path '({json.dumps(str(cache))}) "
            "native-comp-jit-compilation nil) "
            f"(defun bob/elpaca-native-compile (_packages) {action} (list {file})) "
            "(provide 'bob-elpaca))")
        result = subprocess.run(
            [str(manage.APP / "Contents/MacOS/Emacs"), "-Q", "--batch",
             "--eval", setup, "--load", str(manage.HERE / "native-compile.el"),
             "--eval", "(bmacs-update--native-compile nil)"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
        return result, cache

    def test_parallel_worker_output_and_successful_native_artifact(self):
        result, cache = self.run_worker(True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("Compiling", result.stdout)
        self.assertIn("NATIVE COMPILED: 1 package files", result.stdout)
        self.assertTrue(list(cache.rglob("*.eln")))

    def test_missing_native_artifact_is_a_failed_run(self):
        result, cache = self.run_worker(False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Native compilation failed", result.stdout)
        self.assertFalse(list(cache.rglob("*.eln")))


if __name__ == "__main__":
    unittest.main()
