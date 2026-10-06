"""Signing and failure-path tests; never touch the installed app or Keychain."""

import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import manage


FINGERPRINT = "A" * 40
OTHER_FINGERPRINT = "B" * 40
IDENTITIES = f'  1) {FINGERPRINT} "Bmacs Local Development"\n     1 valid identities found\n'
REQUIREMENT = (f'identifier "{manage.BRANDING["CFBundleIdentifier"]}" '
               f'and certificate root = H"{FINGERPRINT}"')


class SigningTests(unittest.TestCase):
    def test_ad_hoc_needs_no_keychain_access(self):
        with patch.object(manage, "output") as output:
            self.assertEqual(manage.resolve_signing_identity("-"), "-")
            output.assert_not_called()

    def test_certificate_name_resolves_to_fingerprint(self):
        with patch.object(manage, "output", return_value=IDENTITIES) as output:
            self.assertEqual(manage.resolve_signing_identity("Bmacs Local Development"),
                             FINGERPRINT)
            output.assert_called_once_with("/usr/bin/security", "find-identity", "-v",
                                           "-p", "codesigning")

    def test_fingerprint_is_case_insensitive(self):
        with patch.object(manage, "output", return_value=IDENTITIES):
            self.assertEqual(manage.resolve_signing_identity(FINGERPRINT.lower()), FINGERPRINT)

    def test_empty_identity_is_not_an_ad_hoc_fallback(self):
        with patch.object(manage, "output") as output:
            for identity in ("", "   "):
                with self.assertRaisesRegex(RuntimeError, "must not be empty"):
                    manage.resolve_signing_identity(identity)
            output.assert_not_called()

    def test_unknown_or_invalid_certificate_is_rejected(self):
        identities = (IDENTITIES
                      + f'  2) {OTHER_FINGERPRINT} "Expired" (CSSMERR_TP_CERT_EXPIRED)\n')
        with patch.object(manage, "output", return_value=identities):
            for identity in ("Missing", "Expired", OTHER_FINGERPRINT):
                with self.assertRaisesRegex(RuntimeError, "No valid code-signing identity"):
                    manage.resolve_signing_identity(identity)

    def test_duplicate_names_require_a_fingerprint(self):
        identities = IDENTITIES + f'  2) {OTHER_FINGERPRINT} "Bmacs Local Development"\n'
        with patch.object(manage, "output", return_value=identities):
            with self.assertRaisesRegex(RuntimeError, "Ambiguous"):
                manage.resolve_signing_identity("Bmacs Local Development")
            self.assertEqual(manage.resolve_signing_identity(FINGERPRINT), FINGERPRINT)

    def test_same_certificate_in_multiple_keychains_is_unambiguous(self):
        with patch.object(manage, "output", return_value=IDENTITIES + IDENTITIES):
            self.assertEqual(manage.resolve_signing_identity("Bmacs Local Development"),
                             FINGERPRINT)

    def test_signing_failure_does_not_retry_with_ad_hoc(self):
        failure = subprocess.CalledProcessError(1, "codesign")
        with patch.object(manage, "run", side_effect=failure) as run, \
             patch.object(manage, "output") as output:
            with self.assertRaises(subprocess.CalledProcessError):
                manage.sign_bundle(Path("Staged.app"), FINGERPRINT)
            run.assert_called_once()
            self.assertEqual(run.call_args.args[4], FINGERPRINT)
            output.assert_not_called()

    def test_certificate_signing_records_default_requirement(self):
        app = Path("Staged.app")
        with patch.object(manage, "run") as run, \
             patch.object(manage, "output", return_value=f'designated => {REQUIREMENT}\n'):
            record = manage.sign_bundle(app, FINGERPRINT)
        run.assert_called_once_with("/usr/bin/codesign", "--force", "--deep", "--sign",
                                    FINGERPRINT, "--identifier",
                                    manage.BRANDING["CFBundleIdentifier"], app)
        self.assertEqual(record, {"mode": "certificate", "identity": FINGERPRINT,
                                  "designated_requirement": REQUIREMENT})

    def test_certificate_mode_rejects_hash_or_identifier_only_requirements(self):
        for requirement in (f'cdhash H"{FINGERPRINT}"',
                            f'identifier "{manage.BRANDING["CFBundleIdentifier"]}"', ""):
            with self.subTest(requirement=requirement), \
                 patch.object(manage, "run"), \
                 patch.object(manage, "output", return_value=f'designated => {requirement}\n'):
                with self.assertRaises(RuntimeError):
                    manage.sign_bundle(Path("Staged.app"), FINGERPRINT)

    def test_ad_hoc_signing_warns_and_records_its_hash_requirement(self):
        requirement = f'cdhash H"{FINGERPRINT}"'
        with patch.object(manage, "run"), \
             patch.object(manage, "output", return_value=f'# designated => {requirement}\n'), \
             contextlib.redirect_stderr(io.StringIO()) as warnings:
            record = manage.sign_bundle(Path("Staged.app"), "-")
        self.assertIn("privacy permissions", warnings.getvalue())
        self.assertEqual(record, {"mode": "ad-hoc", "identity": "-",
                                  "designated_requirement": requirement})

    def test_cli_identity_overrides_environment_and_default(self):
        for environment, arguments, expected in (
                ({}, [], "-"),
                ({"BMACS_SIGNING_IDENTITY": "Bmacs Local Development"}, [],
                 "Bmacs Local Development"),
                ({"BMACS_SIGNING_IDENTITY": "Bmacs Local Development"},
                 ["--signing-identity", FINGERPRINT], FINGERPRINT),
                ({"BMACS_SIGNING_IDENTITY": "Bmacs Local Development"},
                 ["--signing-identity", "-"], "-")):
            with self.subTest(arguments=arguments, environment=environment), \
                 patch.dict(os.environ, environment, clear=True), \
                 patch.object(sys, "argv", ["manage.py", "prepare", "/test-build"] + arguments), \
                 patch.object(sys, "platform", "darwin"), \
                 patch.object(manage, "prepare") as prepare:
                manage.main()
                prepare.assert_called_once_with(Path("/test-build"), expected)


@unittest.skipUnless(sys.platform == "darwin", "requires macOS codesign")
class MacSigningSmokeTests(unittest.TestCase):
    def test_real_ad_hoc_signing_uses_only_a_disposable_bundle(self):
        with tempfile.TemporaryDirectory(prefix="bmacs-signing-") as temp:
            app = Path(temp) / "Bmacs.app"
            binary = app / "Contents/MacOS/Emacs"
            binary.parent.mkdir(parents=True)
            shutil.copyfile("/usr/bin/true", binary)
            binary.chmod(0o755)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(manage.BRANDING))
            with contextlib.redirect_stderr(io.StringIO()):
                record = manage.sign_bundle(app, "-")
            self.assertEqual(record["mode"], "ad-hoc")
            self.assertEqual(record["identity"], "-")
            self.assertIn("cdhash", record["designated_requirement"])
            manage.run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)


class PreparationSigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.checkout = self.root / "source"
        self.checkout.mkdir()
        self.build = self.root / "build"
        self.build.mkdir()
        self.source_app = self.build / "nextstep/Emacs.app"
        (self.build / "Makefile").write_text(
            f'srcdir = {self.checkout}\nns_appdir = {self.source_app}\nns_self_contained = yes\n')
        dump = self.build / "src/emacs.pdmp"
        dump.parent.mkdir()
        dump.write_bytes(b"dump")
        for artifact in manage.ARTIFACTS:
            path = self.source_app / artifact
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"dump" if artifact.endswith(".pdmp") else b"fixture")
        (self.source_app / "Contents/Info.plist").write_bytes(plistlib.dumps(manage.BRANDING))
        strings = self.source_app / "Contents/Resources/English.lproj/InfoPlist.strings"
        strings.parent.mkdir()
        strings.write_text('CFBundleName = "Emacs";\n')

    def test_unavailable_identity_fails_before_building_or_staging(self):
        with patch.object(manage, "ROOT", self.checkout), \
             patch.object(manage, "SUPPORT", self.root / "support"), \
             patch.object(manage, "output", return_value="0 valid identities found\n"), \
             patch.object(manage, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "No valid code-signing identity"):
                manage.prepare(self.build, "Missing")
            run.assert_not_called()
        self.assertFalse((self.root / "support").exists())

    def test_prepare_records_certificate_identity_and_requirement(self):
        results = {"failed": 0, "passed": 3, "skipped": 0}

        def output(*args):
            if args[0] == "/usr/bin/security":
                return IDENTITIES
            if args[:2] == ("/usr/bin/codesign", "--display"):
                return f'# designated => {REQUIREMENT}\n'
            return "test-config-or-revision"

        def run(*args, **kwargs):
            if args[0] == "/usr/bin/ditto":
                shutil.copytree(args[1], args[2])
            if "--load" in args:
                (Path(kwargs["stdout"].name).parent / "batch.json").write_text(json.dumps(results))

        def graphical_checks(app, directory):
            (directory / "graphical.json").write_text(json.dumps(results))

        with patch.object(manage, "ROOT", self.checkout), \
             patch.object(manage, "SUPPORT", self.root / "support"), \
             patch.object(manage, "output", side_effect=output), \
             patch.object(manage, "run", side_effect=run) as commands, \
             patch.object(manage, "verify_bundle") as verify, \
             patch.object(manage, "graphical_checks", side_effect=graphical_checks), \
             patch.object(manage, "stop_installed_app") as stop, \
             contextlib.redirect_stdout(io.StringIO()):
            manage.prepare(self.build, "Bmacs Local Development")
            stop.assert_not_called()
        prepared, = (self.root / "support/bmacs-updates").iterdir()
        manifest = json.loads((prepared / "manifest.json").read_text())
        self.assertEqual(manifest["signing"], {"mode": "certificate", "identity": FINGERPRINT,
                                               "designated_requirement": REQUIREMENT})
        self.assertEqual(manifest["sha256"], manage.hashes(prepared / "Bmacs.app"))
        verify.assert_called_once_with(prepared / "Bmacs.app")
        signing, = [call for call in commands.call_args_list
                    if call.args[0] == "/usr/bin/codesign"]
        self.assertEqual(signing.args[4], FINGERPRINT)
        self.assertEqual([call.args[1] for call in commands.call_args_list
                          if call.args[0] == "gmake"], ["-j1"] * 3)


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
