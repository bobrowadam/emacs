"""Opt-in macOS deployment test using disposable apps and a private server.

Set BMACS_PREPARED to a directory produced by manage.py prepare.
"""

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

import manage


@unittest.skipUnless(os.environ.get("BMACS_PREPARED"), "set BMACS_PREPARED for disposable-app deployment")
class DisposableInstallationTest(unittest.TestCase):
    def test_isolated_install_uses_a_private_server(self):
        prepared = Path(os.environ["BMACS_PREPARED"]).expanduser().resolve()
        with tempfile.TemporaryDirectory(prefix="bmacs-isolated-deploy-", dir="/private/tmp") as temp:
            root = Path(temp)
            app = root / "Bmacs.app"
            source = root / "prepared"
            manage.run("/usr/bin/ditto", prepared, source)
            private_socket = None
            try:
                with patch.object(manage, "APP", app), \
                     patch.object(manage, "SUPPORT", root / "support"):
                    manage.install(source, root / "unused-socket", isolated_launch=True)
                data = json.loads((source / "running.json").read_text())
                private_socket = Path(data["server_socket"])
                self.assertEqual(int(manage.client(app, private_socket, "(emacs-pid)").stdout),
                                 data["pid"])
                self.assertEqual(manage.hashes(app),
                                 json.loads((source / "manifest.json").read_text())["sha256"])
            finally:
                for pid in manage.running_pids(app):
                    os.kill(pid, signal.SIGTERM)
                deadline = time.monotonic() + 10
                while manage.running_pids(app) and time.monotonic() < deadline:
                    time.sleep(0.1)
                for pid in manage.running_pids(app):
                    os.kill(pid, signal.SIGKILL)
                if private_socket:
                    # server-stop normally removes its /tmp directory first.
                    shutil.rmtree(private_socket.parent, ignore_errors=True)

    def test_quit_swap_restart_and_rollback_archive(self):
        prepared = Path(os.environ["BMACS_PREPARED"]).expanduser().resolve()
        with tempfile.TemporaryDirectory(prefix="bmacs-deploy-test-", dir="/private/tmp") as temp:
            root = Path(temp)
            app = root / "Bmacs.app"
            socket = root / "server"
            source = root / "prepared"
            manage.run("/usr/bin/ditto", manage.APP, app)
            manage.run("/usr/bin/ditto", prepared, source)
            old_hashes = manage.hashes(app)
            real_run = manage.run

            def isolated_launch(*args, **kwargs):
                if str(args[0]) == "/usr/bin/open":
                    args = list(args)
                    args.insert(args.index("--args") + 1, "-Q")
                return real_run(*args, **kwargs)

            try:
                code = (f'(progn (setq native-comp-jit-compilation nil) '
                        f'(require (quote server)) '
                        f'(setq server-name {json.dumps(str(socket))}) (server-start))')
                real_run("/usr/bin/open", "-g", "-n", app, "--args", "-Q", "--eval", code)
                deadline = time.monotonic() + 30
                while True:
                    try:
                        old_pid = int(manage.client(app, socket, "(emacs-pid)", timeout=1).stdout)
                        break
                    except (subprocess.SubprocessError, ValueError):
                        self.assertLess(time.monotonic(), deadline, "Private test server did not start")
                        time.sleep(0.2)
                # NS startup can start a native compiler before --eval runs.
                # Wait for owned compiler children instead of weakening the
                # installer's multiple-instance safeguard for this fixture.
                deadline = time.monotonic() + 30
                while manage.running_pids(app) != [old_pid]:
                    self.assertLess(time.monotonic(), deadline,
                                    "Disposable app still has extra processes")
                    time.sleep(0.1)
                unsaved = json.dumps(str(root / "unsaved.txt"))
                manage.client(app, socket,
                              f'(with-current-buffer (find-file-noselect {unsaved}) (insert "test"))')
                with self.assertRaises(subprocess.CalledProcessError):
                    manage.stop_installed_app(app, socket)
                self.assertIn(old_pid, manage.running_pids(app))
                manage.client(app, socket,
                              f'(with-current-buffer (get-file-buffer {unsaved}) (set-buffer-modified-p nil))')
                with patch.object(manage, "APP", app), \
                     patch.object(manage, "SUPPORT", root / "support"), \
                     patch.object(manage, "run", side_effect=isolated_launch):
                    manage.install(source, socket)
                acknowledgment = json.loads((source / "running.json").read_text())
                self.assertNotEqual(acknowledgment["pid"], old_pid)
                self.assertEqual(manage.hashes(app), json.loads((source / "manifest.json").read_text())["sha256"])
                backups = list((root / "support/bmacs-backups").glob("*.zip"))
                self.assertEqual(len(backups), 1)
                restored = root / "restored"
                real_run("/usr/bin/ditto", "-x", "-k", backups[0], restored)
                self.assertEqual(manage.hashes(restored / "Bmacs.app"), old_hashes)
                manage.verify_bundle(restored / "Bmacs.app")
            finally:
                # Only instances from this disposable app path may be stopped.
                for pid in manage.running_pids(app):
                    os.kill(pid, signal.SIGTERM)
                deadline = time.monotonic() + 10
                while manage.running_pids(app) and time.monotonic() < deadline:
                    time.sleep(0.1)
                for pid in manage.running_pids(app):
                    os.kill(pid, signal.SIGKILL)


if __name__ == "__main__":
    unittest.main()
