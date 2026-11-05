# Distribution

Envl targets macOS 14 and later. The packaging scripts build one universal
app containing Apple silicon and Intel executables, then create a DMG and ZIP.
Building requires Xcode with Swift 6, Python 3 and Ruby. Running a downloaded app
does not require Xcode.

## Application identity

Envl was previously named MenuMail. The executable, app bundle, release assets
and cask are named Envl / `envl`. The existing `app.menumail.desktop` bundle
identifier, Keychain service and saved Fold preference value remain stable so
renaming does not discard account connections or preferences. Install one app
with this identifier; remove development copies before testing an installed build.

## Local validation and packages

```bash
swift test
python3 scripts/test-distribution.py
bash scripts/package.sh
```

The default uses an ad-hoc signature and does not contact Apple's signing or
notarization services. It produces:

- `build/Envl.app`
- `build/Envl.dmg` and `build/Envl.zip`
- `build/SHA256SUMS.txt`
- `build/homebrew/Casks/envl.rb`

Packaging verifies both architectures, the app signature, DMG integrity, and
checksums. It also mounts the DMG read only and extracts the ZIP, checks their
app signatures, and compares their contents with the packaged app. These checks
do not run the app or prove Intel runtime compatibility.

All files and localization directories in `Resources/` are copied into the app,
with `Info.plist` placed at the bundle root. Additional mail bridge scripts do
not require a separate copy rule. Rebuilding replaces the generated app bundle.

To repeat the artifact checks without rebuilding:

```bash
bash scripts/validate-package.sh
python3 scripts/homebrew.py --check
```

## Connection scope

The v0.2.0 application only instantiates the Apple Mail client. Gmail and Outlook
appear as **Coming soon** rows and do not start sign-in. No provider client IDs,
OAuth registrations or provider credentials are required to build or release it.
The source retains future direct-provider implementation and synthetic tests,
but that implementation is not connected to the shipping app. Supplying client
IDs does not enable it.

Apple Mail uses accounts already configured in Mail and requests macOS Automation
permission. That bridge is read only: opening a message does not mark it read,
and sending, archiving and deleting are unavailable. Mail must remain running
for synchronization, including its Dock icon.

## Optional Developer ID signing and notarization

The maintainer must configure a Developer ID Application identity and, for
notarization, a `notarytool` keychain profile independently. These scripts do not
discover identities, import keys, create profiles or ask for credentials.

After configuring `ENVL_SIGNING_IDENTITY` yourself, explicitly select signing:

```bash
bash scripts/package.sh --sign
```

This signs the app with hardened runtime, a secure timestamp and the Apple Events
entitlement in `distribution/Envl.entitlements`; it also signs the DMG. The
Apple Events entitlement supports the existing Apple Mail automation bridge.
The app is not sandboxed, so outgoing network access does not require a sandbox
network entitlement. See Apple's [Apple Events entitlement documentation](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.automation.apple-events).

After also configuring `ENVL_NOTARY_PROFILE` to the name of your existing
profile, explicitly select notarization:

```bash
bash scripts/package.sh --sign --notarize
```

This command submits an archive to Apple, requires an `Accepted` result, staples
and validates the app ticket, then creates, signs, submits and staples the DMG.
The ZIP is created from the stapled app after acceptance. It assesses the app and
DMG with Gatekeeper and saves submission receipts as `build/notarization-app.json`
and `build/notarization-dmg.json`. Inspect Apple's notary logs for warnings before
publication. A failed submission stops packaging. See Apple's [custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

The signing and notarization options are opt in; setting environment variables
alone does not enable them. The existing tag workflow continues to build ad-hoc
packages and publish release assets. It does not import signing credentials or
perform notarization. A signed release requires a separately configured release
process that publishes the exact signed artifacts.

Developer ID signing, notarization, fresh Apple Mail permission prompts and Intel
execution require separate checks with the maintainer’s own setup. An ad-hoc local build is not a
notarized release. For opening a downloaded unnotarized app, follow [Apple's macOS instructions](https://support.apple.com/en-us/102445).

## Homebrew cask preparation

`scripts/homebrew.py` reads the packaged app's version and hashes the local DMG.
It writes a cask with a fixed version and SHA-256, a versioned GitHub release URL,
the macOS 14 requirement and `Envl.app` as its install artifact. It checks Ruby
syntax. `--check` compares the complete cask against the current artifact checksum
and app metadata without modifying it.

```bash
python3 scripts/homebrew.py
python3 scripts/homebrew.py --check
ruby -c build/homebrew/Casks/envl.rb
```

Run package validation before generating a cask separately, so the version in
`build/Envl.app` is known to match the DMG contents. The generator also accepts
`--artifact build/Envl.zip` if the ZIP is the intended download; regenerate
and recheck whenever the chosen artifact changes, including after signing or
stapling. Casks must pin the final downloadable bytes. This follows Homebrew's
[Cask Cookbook](https://docs.brew.sh/Cask-Cookbook).

The local cask is preparation for publication. Its versioned URL does not prove a
release exists, and it cannot install until that exact artifact is available.
No tap or release is created by the generator.

After publication is separately authorized and performed:

1. Publish the checked DMG, ZIP and checksums under the matching `v<version>`
   release tag. Keep the chosen artifact's bytes unchanged after cask generation.
2. Copy `build/homebrew/Casks/envl.rb` into `Casks/envl.rb` in
   [berkinduz/tap](https://github.com/berkinduz/tap/tree/main/Casks), review it,
   and publish that tap.
3. Add the tap with `brew tap berkinduz/tap https://github.com/berkinduz/tap`,
   then run `brew style --cask berkinduz/tap/envl` and
   `brew audit --cask --online berkinduz/tap/envl` against the published cask.
4. Test `brew install --cask berkinduz/tap/envl` on a Mac with Gatekeeper
   enabled, then verify app launch and the Apple Mail reader flow.

The tap repository is named `tap`, without the usual `homebrew-` prefix, so its
explicit URL is required when adding it. See Homebrew's [tap documentation](https://docs.brew.sh/Taps).

The cask does not remove quarantine attributes or bypass Gatekeeper. Publishing a
tap and performing a public Homebrew installation are separate from local syntax
and checksum checks.

## CI and the existing release workflow

The CI workflow runs Swift tests, pure cask-generation checks and universal local
packaging with ad-hoc signing. It needs no provider registrations, signing keys or notarization profile. It does not authenticate to a mailbox.

The existing `v*` tag workflow retains release publication. It now runs the same
test and distribution checks before `gh release create`, and rejects a tag that
does not match the packaged app version. Merely editing these files or running
the local scripts does not trigger or publish a release.
