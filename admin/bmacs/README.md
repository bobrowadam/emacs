# Building and updating Bmacs

## Routine update

Run this from macOS Terminal or standalone Pi, not from Bmacs or an Emacs shell:

```sh
python3 /Users/bob/source/emacs/admin/bmacs/update.py
```

Running this command authorizes installation and a Bmacs restart. Save file
buffers first; the installer refuses to quit if any have unsaved changes.

The script configures a separate build directory on first use, then reuses it
for incremental builds. For this checkout, the default is
`/Users/bob/source/emacs-build`. It builds serially, signs with the existing
**Bmacs Local Development** Keychain identity, checks the app, installs it at
`~/Applications/Bmacs.app`, and confirms startup with your normal configuration.
It uses the `bmacs` server socket by default.

It does not create rollback ZIPs. It keeps the previous app temporarily during
installation and removes it after startup is confirmed. It then removes only
this run's prepared staging directory, including its logs and manifest. It
retains the configured build directory for the next incremental build.

Build and check failures leave the installed app unchanged and retain failure
logs. A failure after replacement may leave the new app installed; the installer
prints the recovery directory containing the previous app. There is no automatic
rollback for a user-init failure. Use regular Emacs or Pi CLI while recovering,
and rebuild a previous Git commit if needed. Commit source changes, with review
and approval, if you want to reproduce them later.

The app name, bundle identifier, icon, and installation path stay unchanged.
Reuse the same signing certificate to minimize renewed permission prompts.
The script never creates certificates, changes Keychain trust, or resets macOS
permissions.

Prerequisites are those below and in [AGENTS.md](../../AGENTS.md): bootstrap the
source checkout once using [INSTALL.REPO](../../INSTALL.REPO), install the build
dependencies, and have the persistent signing identity available. First-use
configuration uses Apple's compiler, NS, GPU, tree-sitter, native compilation,
and the Homebrew TIFF library search path. Configuration failures retain
`config.log` in the build directory. The script does not install dependencies.

To also native-compile your built Elpaca packages after Bmacs restarts:

```sh
python3 admin/bmacs/update.py --native-compile
python3 admin/bmacs/update.py --native-compile vui consult
```

With no package names, the flag processes all built Elpaca packages. With names,
it processes only those packages; all built packages remain available as compiler
dependencies. Only sources with current bytecode and missing or stale native
output are compiled. This uses `bob/elpaca-native-compile` from your Emacs
configuration, which must support package selection.

Compilation runs asynchronously in the restarted Bmacs. The updater reports
that compilation was requested, not that it finished; compiler failures appear
in Emacs's `*Async-native-compile-log*` buffer. Without the flag, package
compilation is not requested. An invalid package or failed compiler request
leaves the new Bmacs installed and retains this run's prepared staging.

Optional overrides:

```sh
python3 admin/bmacs/update.py /path/to/separate-build \
  --signing-identity CERTIFICATE_NAME_OR_SHA1 --socket /path/to/bmacs-socket
```

`BMACS_SIGNING_IDENTITY` also overrides the default certificate name. Ad-hoc
signing is rejected. An existing build directory must belong to this checkout;
the script does not reconfigure a directory belonging to another source tree.
The built-in checks use isolated instances but do not verify visible rendering.
Run source-change-specific tests and visual checks before installation.

## Separate preparation and installation

`manage.py prepare` builds in an existing, separately configured build directory
and stages a verified app. It never replaces the installed Bmacs. Installation
is a separate, explicitly authorized `manage.py install` operation; see
[AGENTS.md](../../AGENTS.md) for build configuration, validation, and rollback.

## Microphone access

Preparation adds `NSMicrophoneUsageDescription` to the app's `Info.plist`
before signing. This lets macOS request microphone permission for voice
conversations and dictation, including audio helpers launched by Bmacs.
It does not grant permission automatically. A signed app prepared with this
declaration must be installed and relaunched before it can request access.

## Keep privacy permissions across rebuilds

By default, preparation uses ad-hoc signing (`codesign --sign -`). Its designated
requirement identifies a particular build by its code hash, so rebuilding can
invalidate Screen Recording, Accessibility, and other privacy permissions.
A fixed app name, path, or bundle identifier alone does not fix this.

Use the **same persistent code-signing identity** for each build instead:

```sh
security find-identity -v -p codesigning
python3 admin/bmacs/manage.py prepare /path/to/configured-build \
  --signing-identity "Bmacs Local Development"
```

The identity can be its exact certificate name or the SHA-1 fingerprint printed
by `security find-identity`. A fingerprint avoids ambiguous certificate names.
For routine builds, set this in your build shell's startup file:

```sh
export BMACS_SIGNING_IDENTITY="YOUR_CERTIFICATE_SHA1_FINGERPRINT"
python3 admin/bmacs/manage.py prepare /path/to/configured-build
```

The command-line option overrides the environment variable. Missing, invalid,
expired, or ambiguous identities fail before building or staging. Signing
failures never fall back to ad-hoc signing. To deliberately prepare an ad-hoc
build even with the environment variable set, pass `--signing-identity=-`.
Ad-hoc preparation warns that permissions may need to be granted again.

The helper retains `com.bob.emacs.mode-line` as the bundle identifier and lets
`codesign` generate the certificate-based designated requirement. The manifest
records the selected public certificate fingerprint and designated requirement,
not a private key. Signing uses the Keychain; macOS may ask you to authorize
access to the signing key. Do not supply a Keychain password on the command line.

## Create a local signing identity once

An existing Apple Development or Developer ID Application identity can be used.
For personal local builds, a self-signed code-signing identity is another option
and does not require paid Apple Developer membership:

1. Open **Keychain Access**, then **Certificate Assistant → Create a Certificate**.
2. Name it **Bmacs Local Development**, choose **Self Signed Root** as the identity
   type and **Code Signing** as the certificate type. Store it in your login
   keychain. You can override defaults to choose a longer validity period.
3. If it is not listed as valid by `security find-identity -v -p codesigning`,
   open the certificate's **Trust** settings and trust it for **Code Signing**.
   Only trust a certificate you created and control.
4. Keep that certificate and its private key. Reuse them rather than generating
   a new identity for every build. Keep any backup private and secure.

After the separately authorized installation of the first certificate-signed
build, grant the required macOS permissions again. Subsequent builds signed with
the same identity and bundle identifier should retain those grants. This does
not bypass macOS security policy or guarantee that macOS will never ask again.
Replacing the certificate or changing signing modes can require another grant.
Do not modify the privacy database or weaken the designated requirement to an
identifier-only check.

The helper does not create certificates, change Keychain trust, grant privacy
permissions, or notarize distribution builds.

See Apple's [Inside Code Signing: Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
for how designated requirements preserve code identity across updates.
