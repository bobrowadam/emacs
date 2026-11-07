"""Routine update boundaries; never build or replace the installed Bmacs."""

import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import manage
import update


FINGERPRINT = "A" * 40


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.checkout = self.root / "source"
        self.checkout.mkdir()
        self.build = self.root / "build"
        self.build.mkdir()
        (self.build / "Makefile").write_text("configured")
        self.prepared = self.root / "prepared"
        self.prepared.mkdir()
        (self.prepared / "build.log").write_text("build output")
        self.socket = self.root / "server"
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))
        self.enterContext(patch.object(manage, "ROOT", self.checkout))
        self.identity = self.enterContext(
            patch.object(manage, "resolve_signing_identity", return_value=FINGERPRINT))
        self.prepare = self.enterContext(patch.object(manage, "prepare", return_value=self.prepared))
        self.install = self.enterContext(patch.object(manage, "install"))
        self.run = self.enterContext(patch.object(manage, "run"))
        self.output = self.enterContext(patch.object(manage, "output", return_value="-L/tiff/lib"))

    def test_success_removes_only_this_runs_stage_after_installation(self):
        other = self.root / "another-prepared-build"
        other.mkdir()

        def installed(directory, socket, *, backup):
            self.assertTrue((directory / "build.log").exists())
            self.assertEqual(socket, self.socket)
            self.assertFalse(backup)

        self.install.side_effect = installed
        update.update(self.build, "Existing certificate", self.socket)
        self.prepare.assert_called_once_with(self.build, FINGERPRINT)
        self.run.assert_not_called()
        self.assertFalse(self.prepared.exists())
        self.assertTrue(other.exists())
        self.assertTrue((self.build / "Makefile").exists())

    def test_failed_install_preserves_build_logs(self):
        self.install.side_effect = RuntimeError("startup failed")
        with self.assertRaisesRegex(RuntimeError, "startup failed"):
            update.update(self.build, "Existing certificate", self.socket)
        self.assertEqual((self.prepared / "build.log").read_text(), "build output")

    def test_failed_preparation_never_installs_or_cleans_failure_logs(self):
        self.prepare.side_effect = RuntimeError("checks failed")
        with self.assertRaisesRegex(RuntimeError, "checks failed"):
            update.update(self.build, "Existing certificate", self.socket)
        self.install.assert_not_called()
        self.assertTrue((self.prepared / "build.log").exists())

    def test_unavailable_or_ad_hoc_signing_never_configures_or_installs(self):
        with self.assertRaisesRegex(RuntimeError, "persistent"):
            update.update(self.build, "-", self.socket)
        self.identity.assert_not_called()
        self.identity.side_effect = RuntimeError("identity unavailable")
        with self.assertRaisesRegex(RuntimeError, "identity unavailable"):
            update.update(self.build, "Missing", self.socket)
        self.run.assert_not_called()
        self.prepare.assert_not_called()
        self.install.assert_not_called()

    def test_source_directory_is_never_used_as_a_build_directory(self):
        for build in (self.checkout, self.checkout / "build"):
            with self.subTest(build=build):
                with self.assertRaisesRegex(RuntimeError, "outside"):
                    update.update(build, "Existing certificate", self.socket)
        self.run.assert_not_called()
        self.prepare.assert_not_called()

    def test_fresh_build_is_configured_outside_source_before_preparation(self):
        (self.build / "Makefile").unlink()
        update.update(self.build, "Existing certificate", self.socket)
        self.assertEqual(self.run.call_args.args,
                         (self.checkout / "configure", "--with-ns", "--with-gpu",
                          "--with-tree-sitter", "--with-native-compilation=yes"))
        self.assertEqual(self.run.call_args.kwargs["cwd"], self.build)
        self.assertEqual(self.run.call_args.kwargs["env"]["CC"], "/usr/bin/gcc")
        self.assertEqual(self.run.call_args.kwargs["env"]["LDFLAGS"], "-L/tiff/lib")


if __name__ == "__main__":
    unittest.main()
