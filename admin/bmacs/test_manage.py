"""Failure-path tests for Bmacs installation; never touch the real app."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import manage


class InstallationSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "Bmacs.app"
        self.app.mkdir()
        (self.app / "original").write_text("old app")
        self.staged = self.root / "Next.app"
        self.previous = self.root / "Previous.app"

    def test_failed_rename_restores_original(self):
        # A missing source causes a real filesystem failure after moving the old app.
        with self.assertRaises(FileNotFoundError):
            manage.activate(self.staged, self.app, self.previous)
        self.assertEqual((self.app / "original").read_text(), "old app")
        self.assertFalse(self.previous.exists())

    def test_failed_installed_startup_restores_original(self):
        self.staged.mkdir()
        (self.staged / "replacement").write_text("new app")
        with patch.object(manage, "verify_bundle", side_effect=RuntimeError("bad dump")):
            with self.assertRaisesRegex(RuntimeError, "bad dump"):
                manage.activate(self.staged, self.app, self.previous)
        self.assertTrue((self.app / "original").exists())
        self.assertTrue((self.staged / "replacement").exists())
        self.assertFalse(self.previous.exists())

    def test_changed_prepared_artifact_never_quits_or_replaces_app(self):
        prepared = self.root / "prepared"
        bundle = prepared / "Bmacs.app"
        for artifact in manage.ARTIFACTS:
            path = bundle / artifact
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"verified")
        (prepared / "manifest.json").write_text(json.dumps({"sha256": manage.hashes(bundle)}))
        (bundle / manage.ARTIFACTS[0]).write_bytes(b"changed after verification")
        with patch.object(manage, "APP", self.app), \
             patch.object(manage, "stop_installed_app") as stop, \
             patch.object(manage, "activate") as activate:
            with self.assertRaisesRegex(RuntimeError, "Prepared artifacts changed"):
                manage.install(prepared, self.root / "server")
            stop.assert_not_called()
            activate.assert_not_called()
        self.assertTrue((self.app / "original").exists())

    def test_installer_inside_target_emacs_refuses_to_quit(self):
        with patch.object(manage, "running_pids", return_value=[99999]), \
             patch.object(manage.os, "getppid", return_value=99999), \
             patch.object(manage, "client") as client:
            with self.assertRaisesRegex(RuntimeError, "standalone Pi or Terminal"):
                manage.stop_installed_app(self.app, self.root / "server")
            client.assert_not_called()
        self.assertTrue((self.app / "original").exists())

    def test_isolated_install_refuses_to_contact_running_bmacs(self):
        with patch.object(manage, "running_pids", return_value=[99999]), \
             patch.object(manage, "client") as client:
            with self.assertRaisesRegex(RuntimeError, "Quit Bmacs"):
                manage.install(self.root, self.root / "unused-socket", isolated_launch=True)
            client.assert_not_called()

    def test_startup_ack_must_match_live_installed_process(self):
        ready = self.root / "started.json"
        data = {"pid": 42, "executable": str(self.app / "Contents/MacOS/Emacs"),
                "init_error": False}
        ready.write_text(json.dumps(data))
        with patch.object(manage, "running_pids", return_value=[43]):
            with self.assertRaisesRegex(RuntimeError, "Startup acknowledgment"):
                manage.confirm_running(self.app, ready)
        data["pid"] = 43
        data["init_error"] = True
        ready.write_text(json.dumps(data))
        with patch.object(manage, "running_pids", return_value=[43]):
            with self.assertRaisesRegex(RuntimeError, "initialization error"):
                manage.confirm_running(self.app, ready)


if __name__ == "__main__":
    unittest.main()
