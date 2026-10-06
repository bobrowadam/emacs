# Bmacs

Bmacs is Bob's Emacs fork. It includes GPU rendering.

## Branches and remotes

- Use `bob` for fork development.
- Create linked worktrees under `.worktrees/` in the main checkout. Keep builds outside source worktrees.
- `master` follows the upstream Emacs mirror.
- `origin` points to Bob's fork.
- `upstream` points to the upstream mirror.

## Contribution scope

Agent-assisted implementation is permitted in this fork. Upstream prohibits LLM-generated contributions and discourages LLM-generated bug reports and planning. Do not treat permission to work here as permission to submit generated material upstream.

## Compatibility

Preserve standard Emacs behavior unless Bob approves a change. Keep fork-specific behavior opt-in where practical. Changes to Lisp APIs and defaults require explicit agreement.

## Build and validation

Use a separate build directory. For redisplay changes, check both graphical and terminal behavior. Prioritize graphical validation without dropping terminal support. Report skipped tests separately from passed tests. Geometry checks do not establish that visible rendering is correct.

Do not restart Bob's running Emacs unless explicitly requested. Use an isolated instance for validation.

## Installed macOS app

Treat [Bmacs.app](/Users/bob/Applications/Bmacs.app) as Bob's stable, usable version. It contains a copy of the built executable and its resources, not a link to a temporary build directory. Routine builds and tests must not replace it. Test new builds in isolation.

Update the installed app only when explicitly requested. Preserve its installation path, app name, bundle identifier, and icon unless Bob requests a change. Verify the replacement before installation and retain a recoverable previous version.

Keep the installed app independent of temporary build directories. Rebuilding or cleaning the source tree must not break it.

## Repeatable build and installation

Use `admin/bmacs/manage.py` rather than assembling bundles with ad hoc commands. It requires Python 3, GNU Make (`gmake`), macOS signing tools, and an already configured separate build directory. Bootstrap a fresh checkout as described in [INSTALL.REPO](INSTALL.REPO); see [nextstep/INSTALL](nextstep/INSTALL) for NS build requirements.

Configure once outside the checkout. The current Bmacs configuration uses `--with-ns --with-gpu --with-tree-sitter --with-native-compilation=no`, with the default self-contained NS installation. On this Homebrew setup, also pass `LDFLAGS="$(pkg-config --libs-only-L libtiff-4)"` to retain the TIFF library search path. Keep the build's `ns_appdir` inside that build directory, never pointed at the installed Bmacs.

Then use these two explicit operations:

```sh
python3 admin/bmacs/manage.py prepare /path/to/configured-build
python3 admin/bmacs/manage.py install "/path/printed/by/prepare"
```

- **Prepare** builds serially, runs sanity checks, installs into the build directory, and stages a complete app under `~/Library/Application Support/bmacs-updates/`. It applies the source-controlled branding and `admin/bmacs/Emacs.icns`, signs the bundle, checks startup, and runs focused batch and hidden-GUI tests. It never updates the installed app.
- **Signing**: `prepare --signing-identity NAME_OR_SHA1` or `BMACS_SIGNING_IDENTITY` selects a persistent Keychain code-signing identity so privacy grants can survive rebuilds. The default remains ad-hoc signing with a warning. An unavailable or ambiguous configured identity fails before building, and signing failures must never silently fall back to ad-hoc. Setup instructions are in [admin/bmacs/README.md](admin/bmacs/README.md). Never create certificates, alter Keychain trust, or regrant permissions without authorization.
- **Install** is a separate, explicitly authorized action. It verifies the prepared artifacts, creates a rollback ZIP, refuses to quit with unsaved file buffers, quits Bmacs, swaps whole bundles, and reopens Bmacs in the background. It confirms the new process's startup acknowledgment before reporting success. Use `--socket PATH` if the current Emacs uses a nondefault server socket; if it has no server, quit it manually first.
- Run installation from standalone Pi or Terminal, not through tools hosted by the Emacs being replaced. The helper rejects installation when the target Emacs is its ancestor. Do not add a background updater or depend on Emacs surviving its own replacement.
- When native Emacs is in use, `install PREPARED --isolated-launch` requires Bmacs to be stopped and starts it with `-Q` and its own private socket. It does not load user init or Mentat; use the printed socket for Bmacs-only checks, and never assume the default socket belongs to Bmacs.
- Preserve the helper's logs, manifest, and rollback. The manifest records source revision, dirty state, configure options, checks, and artifact hashes. The portable dump's embedded revision alone is not proof of which build was installed.
- Report **BUILT**, **STAGED**, **INSTALLED**, and **RUNNING** distinctly. A prepared app is not an installed app; a successful copy is not a confirmed running process. If startup fails, report the recovery directory instead of claiming completion.
- Report skipped tests separately from passes. Hidden-frame checks do not cover visible painting or visible mode-line behavior. Run additional checks appropriate to the source change before approving installation.

When changing the helper, run `python3 -m unittest discover -s admin/bmacs -p 'test_*.py'`. For deployment changes, also run `BMACS_PREPARED="/path/printed/by/prepare" python3 -m unittest discover -s admin/bmacs -p 'test_*.py'`; this opt-in test swaps a disposable app and leaves the working installation alone. It skips when `BMACS_PREPARED` is unset.

The GPU presentation regression uses the same `BMACS_PREPARED` setting. Run it alone with `python3 -m unittest discover -s admin/bmacs -p test_gpu.py`. It maps a non-focusing Bmacs window behind other windows and checks private-server responsiveness while frames are actually presented. Hidden frames and nested Lisp waits do not exercise the top-level event-loop starvation this test guards against.
