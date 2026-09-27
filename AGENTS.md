# Bmacs

Bmacs is Bob's Emacs fork. It includes GPU rendering and native two-row mode lines.

## Branches and remotes

- Use `bob` for fork development.
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
