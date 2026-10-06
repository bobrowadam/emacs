# Preparing and signing Bmacs

`manage.py prepare` builds in an existing, separately configured build directory
and stages a verified app. It never replaces the installed Bmacs. Installation
is a separate, explicitly authorized `manage.py install` operation; see
[AGENTS.md](../../AGENTS.md) for build configuration, validation, and rollback.

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
