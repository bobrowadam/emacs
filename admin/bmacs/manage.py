#!/usr/bin/env python3
"""Prepare and explicitly install Bmacs on macOS.  Uses only Python's stdlib."""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
APP = Path.home() / "Applications/Bmacs.app"
SUPPORT = Path.home() / "Library/Application Support"
SOCKET = Path(tempfile.gettempdir()) / f"emacs{os.getuid()}/server"
BRANDING = {
    "CFBundleName": "Bmacs",
    "CFBundleDisplayName": "Bmacs",
    "CFBundleIdentifier": "com.bob.emacs.mode-line",
    "CFBundleIconFile": "Emacs.icns",
    "CFBundleExecutable": "Emacs",
}
ARTIFACTS = (
    "Contents/MacOS/Emacs",
    "Contents/MacOS/libexec/Emacs.pdmp",
    "Contents/Info.plist",
    "Contents/Resources/Emacs.icns",
)
STARTUP_CHECK = "(unless (and (featurep 'ns) (fboundp 'gpu-backend-p)) (error \"Missing NS/GPU support\"))"


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def output(*args):
    return run(*args, capture_output=True, text=True).stdout.strip()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def hashes(app):
    return {name: hashlib.sha256((app / name).read_bytes()).hexdigest()
            for name in ARTIFACTS}


def resolve_signing_identity(identity):
    """Resolve a certificate name or SHA-1 to one valid Keychain identity."""
    identity = identity.strip()
    require(identity, "Signing identity must not be empty; use '-' for ad-hoc signing")
    if identity == "-":
        return identity
    identities = re.findall(
        r'^\s*\d+\) ([0-9A-Fa-f]{40}) "(.*)"\s*$',
        output("/usr/bin/security", "find-identity", "-v", "-p", "codesigning"),
        re.MULTILINE)
    matches = {fingerprint.upper() for fingerprint, name in identities
               if identity.upper() == fingerprint.upper() or identity == name}
    require(matches, f"No valid code-signing identity matches {identity!r}; "
            "check 'security find-identity -v -p codesigning'")
    require(len(matches) == 1,
            f"Ambiguous code-signing identity {identity!r}; use its SHA-1 fingerprint")
    return matches.pop()


def sign_bundle(app, identity):
    """Sign a staged bundle and record its public code identity, never its key."""
    if identity == "-":
        print("Warning: ad-hoc signing changes Bmacs's identity on rebuild; "
              "privacy permissions may need to be granted again. "
              "Set BMACS_SIGNING_IDENTITY or use --signing-identity.", file=sys.stderr)
    run("/usr/bin/codesign", "--force", "--deep", "--sign", identity, "--identifier",
        BRANDING["CFBundleIdentifier"], app)
    requirements = output("/usr/bin/codesign", "--display", "--requirements", "-", app)
    match = re.search(r'^#?\s*designated => (.+)$', requirements, re.MULTILINE)
    require(match, "Signed bundle has no designated requirement")
    requirement = match.group(1)
    if identity != "-":
        require("cdhash" not in requirement
                and re.search(r'\b(?:certificate|anchor)\b', requirement),
                "Signing did not produce a certificate-based designated requirement")
    return {"mode": "ad-hoc" if identity == "-" else "certificate",
            "identity": identity, "designated_requirement": requirement}


def verify_bundle(app):
    require(app.is_dir() and not app.is_symlink(), f"Not a standalone app: {app}")
    require(not any(p.is_symlink() for p in app.rglob("*")),
            f"Bundle contains symlinks: {app}")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(all(info.get(k) == v for k, v in BRANDING.items()),
            f"Unexpected application identity: {app}")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    run(app / "Contents/MacOS/Emacs", "-Q", "--batch", "--eval",
        STARTUP_CHECK, timeout=30)


def brand_bundle(app):
    contents = app / "Contents"
    plist = contents / "Info.plist"
    info = plistlib.loads(plist.read_bytes())
    info.update(BRANDING)
    for service in info.get("NSServices", []):
        label = service["NSMenuItem"]["default"].split("/", 1)[1]
        service["NSMenuItem"]["default"] = f"Bmacs/{label}"
        service["NSPortName"] = "Bmacs"
    plist.write_bytes(plistlib.dumps(info, sort_keys=False))
    strings = contents / "Resources/English.lproj/InfoPlist.strings"
    text, count = re.subn(r'^CFBundleName = .*;$', 'CFBundleName = "Bmacs";',
                         strings.read_text(), flags=re.MULTILINE)
    require(count == 1, "Could not find the localized application name")
    strings.write_text(text)
    shutil.copyfile(HERE / "Emacs.icns", contents / "Resources/Emacs.icns")


def client(app, socket, code, timeout=10):
    return run(app / "Contents/MacOS/bin/emacsclient", "--socket-name", socket,
               "--eval", code, capture_output=True, text=True, timeout=timeout)


def graphical_checks(app, directory):
    """Use a private daemon; never connect to the user's Emacs server."""
    # macOS Unix-domain socket paths have a small length limit.
    with tempfile.TemporaryDirectory(prefix="bmacs-check-", dir="/tmp") as temp:
        socket = Path(temp) / "server"
        with (directory / "graphical.log").open("w") as log:
            process = subprocess.Popen(
                [str(app / "Contents/MacOS/Emacs"), "-Q", f"--fg-daemon={socket}"],
                stdout=log, stderr=subprocess.STDOUT)
            try:
                deadline = time.monotonic() + 30
                while True:
                    require(process.poll() is None, "Graphical test daemon exited")
                    try:
                        client(app, socket, "t", timeout=1)
                        break
                    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
                        require(time.monotonic() < deadline,
                                "Graphical test daemon did not become ready")
                        time.sleep(0.2)
                code = (f'(progn (load {json.dumps(str(HERE / "checks.el"))} nil t) '
                        f'(bmacs-checks-run t {json.dumps(str(directory / "graphical.json"))}))')
                client(app, socket, code, timeout=60)
                client(app, socket, "(run-at-time 0.1 nil (function kill-emacs))")
                require(process.wait(timeout=10) == 0,
                        "Graphical test daemon failed during shutdown")
            finally:
                # Only this helper's isolated process may be forcibly stopped.
                if process.poll() is None:
                    process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


def prepare(build, signing_identity="-"):
    build = build.expanduser().resolve()
    require(build != ROOT and ROOT not in build.parents,
            "Use a build directory outside the source checkout")
    makefile = (build / "Makefile").read_text()
    settings = dict(re.findall(r"^(srcdir|ns_appdir|ns_self_contained)\s*=\s*(.*)$",
                               makefile, re.MULTILINE))
    require(Path(settings.get("srcdir", "")).resolve() == ROOT,
            "Build directory belongs to another source checkout")
    source_app = build / "nextstep/Emacs.app"
    require(settings.get("ns_self_contained") == "yes"
            and Path(settings.get("ns_appdir", "")).resolve() == source_app,
            "Configure a self-contained NS build whose install target stays in the build directory")
    # Fail before building or staging, never silently fall back to ad-hoc signing.
    signing_identity = resolve_signing_identity(signing_identity)
    updates = SUPPORT / "bmacs-updates"
    updates.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="prepared-", dir=updates))
    print(f"Preparing in {directory}\nBuild output: {directory / 'build.log'}", flush=True)
    manifest = {
        "source_revision": output("git", "-C", ROOT, "rev-parse", "HEAD"),
        "source_dirty": bool(output("git", "-C", ROOT, "status", "--porcelain")),
        "configure": output(build / "config.status", "--config"),
        "prepared_at": datetime.datetime.now().astimezone().isoformat(),
    }
    with (directory / "build.log").open("w") as log:
        # Serial execution avoids racing temacs relinking against portable dumping.
        for target in ("all", "sanity-check", "install"):
            run("gmake", "-j1", target, cwd=build, stdout=log, stderr=subprocess.STDOUT)
    print("BUILT: compilation, sanity check, and build-directory installation passed", flush=True)
    app = directory / "Bmacs.app"
    run("/usr/bin/ditto", source_app, app)
    require((app / ARTIFACTS[1]).read_bytes() == (build / "src/emacs.pdmp").read_bytes(),
            "Installed portable dump does not match the build")
    brand_bundle(app)
    manifest["signing"] = sign_bundle(app, signing_identity)
    verify_bundle(app)
    with (directory / "batch.log").open("w") as log:
        code = f'(bmacs-checks-run nil {json.dumps(str(directory / "batch.json"))})'
        run(app / "Contents/MacOS/Emacs", "-Q", "--batch", "--load", HERE / "checks.el",
            "--eval", code, timeout=60, stdout=log, stderr=subprocess.STDOUT)
    graphical_checks(app, directory)
    manifest["checks"] = {}
    for name, minimum in (("batch", 2), ("graphical", 3)):
        results = json.loads((directory / f"{name}.json").read_text())
        require(results["failed"] == 0 and results["passed"] >= minimum,
                f"{name} checks failed or required tests were skipped; see {directory}")
        manifest["checks"][name] = results
        print(f"{name}: {results}", flush=True)
    manifest["checks"]["visible_rendering"] = "not checked; hidden-frame tests only"
    manifest["sha256"] = hashes(app)
    (directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"STAGED: {directory}\nInstalled app unchanged. Visible rendering remains unchecked.")
    print(f"To install: python3 {HERE / 'manage.py'} install {json.dumps(str(directory))}")


def running_pids(app):
    executable = str(app / "Contents/MacOS/Emacs")
    processes = output("/bin/ps", "-axo", "pid=,comm=")
    return [int(parts[0]) for line in processes.splitlines()
            if len(parts := line.strip().split(None, 1)) == 2 and parts[1] == executable]


def stop_installed_app(app, socket):
    pids = running_pids(app)
    require(len(pids) <= 1, "Multiple Bmacs instances are running; quit them first")
    if not pids:
        return
    pid = pids[0]
    parent = os.getppid()
    while parent > 1:
        require(parent != pid,
                "Run install from standalone Pi or Terminal, not from the Emacs being replaced")
        parent = int(output("/bin/ps", "-p", parent, "-o", "ppid="))
    code = (f'(progn (unless (= (emacs-pid) {pid}) (error "Wrong Emacs server")) '
            '(when (seq-some (lambda (b) (with-current-buffer b '
            '(and buffer-file-name (buffer-modified-p)))) (buffer-list)) '
            '(error "Unsaved file buffers; refusing to quit")) '
            '(run-at-time 0.5 nil (function kill-emacs)) (emacs-pid))')
    client(app, socket, code)
    deadline = time.monotonic() + 45
    while running_pids(app):
        require(time.monotonic() < deadline,
                "Bmacs did not quit; installed bundle has not been replaced")
        time.sleep(0.25)


def activate(staged, app, previous):
    """Restore the original bundle if the swap or batch startup check fails."""
    if app.exists():
        app.rename(previous)
    try:
        staged.rename(app)
        verify_bundle(app)
    except BaseException:
        if app.exists():
            app.rename(staged)
        if previous.exists():
            previous.rename(app)
        raise


def confirm_running(app, ready):
    data = json.loads(ready.read_text())
    require(not data["init_error"], "Bmacs reported an initialization error")
    require(data["executable"] == str(app / "Contents/MacOS/Emacs")
            and data["pid"] in running_pids(app),
            "Startup acknowledgment does not belong to the installed Bmacs process")
    return data


def install(directory, socket, isolated_launch=False):
    directory = directory.expanduser().resolve()
    if isolated_launch:
        require(not running_pids(APP),
                "Quit Bmacs before an isolated install; only Bmacs may be stopped")
    manifest = json.loads((directory / "manifest.json").read_text())
    source = directory / "Bmacs.app"
    require(hashes(source) == manifest["sha256"], "Prepared artifacts changed; prepare again")
    verify_bundle(source)
    APP.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".bmacs-install-", dir=APP.parent))
    print(f"Installation staging/recovery directory: {staging}", flush=True)
    staged = staging / "Bmacs.app"
    run("/usr/bin/ditto", source, staged)
    verify_bundle(staged)
    if APP.exists():
        verify_bundle(APP)
        backups = SUPPORT / "bmacs-backups"
        backups.mkdir(parents=True, exist_ok=True)
        backup = backups / f"Bmacs-before-{staging.name.lstrip('.')}.zip"
        run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", APP, backup)
        with zipfile.ZipFile(backup) as archive:
            require(archive.testzip() is None, f"Rollback ZIP failed verification: {backup}")
        print(f"Rollback: {backup}", flush=True)
    private_socket = None
    if isolated_launch:
        private_socket = Path(tempfile.mkdtemp(prefix="bmacs-live-", dir="/tmp")) / "server"
    # If Bmacs starts after the earlier check, a private, as-yet-unbound
    # socket makes us fail safely instead of contacting native Emacs.
    stop_installed_app(APP, private_socket if isolated_launch else socket)
    activate(staged, APP, staging / "Previous.app")
    print(f"INSTALLED: {APP}", flush=True)
    # A startup acknowledgment works even when user init does not start a server.
    ready = staging / "started.json"
    pending = staging / "started.tmp"
    server_setup = (f'(require (quote server)) '
                    f'(setq server-name {json.dumps(str(private_socket))}) '
                    '(server-start) ') if isolated_launch else ''
    code = (f'(progn {server_setup}(require (quote json)) '
             f'(with-temp-file {json.dumps(str(pending))} '
            '(insert (json-encode `((pid . ,(emacs-pid)) '
            '(executable . ,(expand-file-name invocation-name invocation-directory)) '
            '(init_error . ,(if init-file-had-error t :json-false)))))) '
            f'(rename-file {json.dumps(str(pending))} {json.dumps(str(ready))}))')
    launch_args = ("-Q", "--eval", code) if isolated_launch else ("--eval", code)
    run("/usr/bin/open", "-g", "-n", APP, "--args", *launch_args, timeout=15)
    deadline = time.monotonic() + 60
    while not ready.exists():
        require(time.monotonic() < deadline,
                f"Installed, but startup was not confirmed. Recovery files: {staging}")
        time.sleep(0.25)
    data = confirm_running(APP, ready)
    if private_socket:
        require(int(client(APP, private_socket, "(emacs-pid)").stdout) == data["pid"],
                "Private server does not belong to the installed Bmacs")
        data["server_socket"] = str(private_socket)
    require(hashes(APP) == manifest["sha256"], "Installed artifacts differ from prepared artifacts")
    (directory / "running.json").write_text(json.dumps(data, indent=2) + "\n")
    shutil.rmtree(staging)
    print(f"RUNNING: PID {data['pid']} from {APP}; no initialization error")
    if private_socket:
        print(f"Isolated -Q Bmacs server: {private_socket}; user init was not loaded")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("prepare", help="build and verify without changing the installed app")
    build.add_argument("build_directory", type=Path, help="existing configured, separate NS build directory")
    build.add_argument("--signing-identity", default=os.environ.get("BMACS_SIGNING_IDENTITY", "-"),
                       help="Keychain code-signing certificate name or SHA-1 fingerprint "
                       "(default: BMACS_SIGNING_IDENTITY, otherwise '-' for ad-hoc)")
    deploy = commands.add_parser("install", help="back up, quit, replace, and reopen Bmacs (explicit authorization)")
    deploy.add_argument("prepared_directory", type=Path, help="directory printed by prepare")
    deploy.add_argument("--socket", type=Path, default=SOCKET, help="current Bmacs server socket")
    deploy.add_argument("--isolated-launch", action="store_true",
                        help="require Bmacs stopped, then launch -Q on a private socket")
    args = parser.parse_args()
    require(sys.platform == "darwin", "This helper is for macOS")
    if args.command == "prepare":
        prepare(args.build_directory, args.signing_identity)
    else:
        install(args.prepared_directory, args.socket, args.isolated_launch)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        sys.exit(f"Bmacs: {error}")
