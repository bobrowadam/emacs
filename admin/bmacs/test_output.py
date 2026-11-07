"""Live command output and package-worker boundaries; never install an app."""

import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import manage
import update


class OutputTests(unittest.TestCase):
    def test_stdout_and_stderr_are_logged_before_the_child_exits(self):
        with tempfile.TemporaryDirectory() as temp:
            acknowledgment = Path(temp) / "seen"

            class Terminal(io.StringIO):
                def write(self, text):
                    if "first" in text:
                        acknowledgment.touch()
                    return super().write(text)

            terminal = Terminal()
            code = (
                "import pathlib, sys, time\n"
                f"ack = pathlib.Path({str(acknowledgment)!r})\n"
                "print('first', flush=True)\n"
                "deadline = time.monotonic() + 5\n"
                "while not ack.exists() and time.monotonic() < deadline: time.sleep(0.01)\n"
                "if not ack.exists(): sys.exit(9)\n"
                "print('diagnostic', file=sys.stderr, flush=True)\n")
            with (Path(temp) / "build.log").open("w+") as log, \
                    contextlib.redirect_stdout(terminal):
                manage.run_logged(sys.executable, "-c", code, log=log)
                log.seek(0)
                self.assertEqual(log.read(), terminal.getvalue())
            self.assertIn("diagnostic", terminal.getvalue())

    def test_failed_command_preserves_its_output_and_exit_status(self):
        terminal, log = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(terminal), \
                self.assertRaises(subprocess.CalledProcessError) as failure:
            manage.run_logged(sys.executable, "-c",
                              "print('compiler failed'); raise SystemExit(7)", log=log)
        self.assertEqual(failure.exception.returncode, 7)
        self.assertEqual(log.getvalue(), "compiler failed\n")
        self.assertEqual(terminal.getvalue(), log.getvalue())


class PackageWorkerTests(unittest.TestCase):
    def test_context_and_package_names_reach_the_isolated_worker(self):
        context = {"helper": "/config/bob-elpaca.el", "builds": "/packages/builds/",
                   "load_path": ["/packages/elpaca", None]}
        with tempfile.TemporaryDirectory() as temp, \
                patch.object(manage, "client") as client, \
                patch.object(manage, "run_logged") as run, \
                contextlib.redirect_stdout(io.StringIO()):
            client.return_value.stdout = json.dumps(json.dumps(context))
            update.compile_packages(["vui", 'name"with-quote'], Path("/socket"), Path(temp))
            args, kwargs = run.call_args
            self.assertEqual(args[0], manage.APP / "Contents/MacOS/Emacs")
            self.assertEqual(args[1:3], ("-Q", "--batch"))
            self.assertIn('load-path \'("/packages/elpaca" nil)', args[4])
            self.assertIn("native-comp-jit-compilation nil", args[4])
            self.assertEqual(args[6], context["helper"])
            self.assertIn('("vui" "name\\"with-quote")', args[-1])
            self.assertEqual(Path(kwargs["log"].name), Path(temp) / "native.log")


if __name__ == "__main__":
    unittest.main()
