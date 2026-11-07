#!/usr/bin/env python3
"""Build, check, install, and reopen Bmacs without retaining app backups."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

import manage


def compile_packages(packages, socket, directory):
    """Run package compilation separately so the interactive app stays usable."""
    code = ("(progn (require 'bob-elpaca) (require 'json) "
            "(json-encode (list :helper (symbol-file 'bob/elpaca-native-compile 'defun) "
            ":builds elpaca-builds-directory :load_path (vconcat load-path))))")
    result = manage.client(manage.APP, socket, code)
    context = json.loads(json.loads(result.stdout))
    load_path = " ".join("nil" if path is None else json.dumps(path)
                         for path in context["load_path"])
    setup = (f"(setq load-path '({load_path}) "
             f"elpaca-builds-directory {json.dumps(context['builds'])} "
             "native-comp-jit-compilation nil)")
    names = " ".join(json.dumps(package) for package in packages)
    worker = manage.HERE / "native-compile.el"
    logfile = directory / "native.log"
    print(f"NATIVE COMPILATION: package workers; log: {logfile}", flush=True)
    with logfile.open("w") as log:
        manage.run_logged(manage.APP / "Contents/MacOS/Emacs", "-Q", "--batch",
                          "--eval", setup, "--load", context["helper"],
                          "--load", worker,
                          "--eval", f"(bmacs-update--native-compile '({names}))",
                          log=log)


def update(build, signing_identity, socket, native_compile=None):
    """Keep failure logs; remove this run's staging only after confirmed startup."""
    manage.require(signing_identity.strip() != "-",
                   "Routine updates require the existing persistent signing identity")
    identity = manage.resolve_signing_identity(signing_identity)
    build = build.expanduser().resolve()
    manage.require(build != manage.ROOT and manage.ROOT not in build.parents,
                   "Use a build directory outside the source checkout")
    if not (build / "Makefile").exists():
        build.mkdir(parents=True, exist_ok=True)
        environment = dict(os.environ, CC="/usr/bin/gcc",
                           LDFLAGS=manage.output("pkg-config", "--libs-only-L", "libtiff-4"))
        manage.run(manage.ROOT / "configure", "--with-ns", "--with-gpu",
                   "--with-tree-sitter", "--with-native-compilation=yes",
                   cwd=build, env=environment)
    directory = manage.prepare(build, identity, stream=True)
    manage.install(directory, socket, backup=False)
    if native_compile is not None:
        compile_packages(native_compile, socket, directory)
    shutil.rmtree(directory)
    print("UPDATED: Bmacs startup confirmed; temporary staging removed. "
          "Configured build directory retained for incremental builds.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_directory", nargs="?", type=Path,
                        default=manage.ROOT.parent / f"{manage.ROOT.name}-build",
                        help="separate incremental build directory (default: CHECKOUT-build beside checkout)")
    parser.add_argument("--signing-identity",
                        default=os.environ.get("BMACS_SIGNING_IDENTITY", "Bmacs Local Development"),
                        help="existing Keychain certificate name or SHA-1; never ad-hoc")
    parser.add_argument("--socket", type=Path, default=manage.SOCKET.with_name("bmacs"),
                        help="current Bmacs server socket (default: bmacs)")
    parser.add_argument("--native-compile", nargs="*", metavar="PACKAGE",
                        help="stream and wait for package native compilation after restart; "
                             "name built Elpaca packages, or omit names for all packages")
    args = parser.parse_args()
    manage.require(sys.platform == "darwin", "This helper is for macOS")
    update(args.build_directory, args.signing_identity, args.socket,
           native_compile=args.native_compile)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        sys.exit(f"Bmacs update: {error}")
