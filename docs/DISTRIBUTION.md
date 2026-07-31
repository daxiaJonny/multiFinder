# Distribution

MultiFinder supports two distribution paths:

- **Automated GitHub Release**: requires no Apple credentials. It produces an
  ad-hoc-signed, unnotarized Universal app for `arm64` and `x86_64`.
- **Developer ID release**: requires an Apple Developer membership. It uses
  Hardened Runtime, Developer ID signing, notarization, and ticket stapling.

MultiFinder is **not** an App Store app.

## Why not the App Store?

The App Store requires App Sandbox. A sandboxed process can only touch files
the user has explicitly granted through open/save panels (plus a few narrow
entitlement carve-outs), which breaks MultiFinder's core feature: freely
browsing arbitrary filesystem locations across multiple panes. The App Store
path was considered and rejected for that reason.

If that decision ever changed, an App Store build would need:

- `com.apple.security.app-sandbox` enabled plus
  `com.apple.security.files.user-selected.read-write`,
- every browsed location acquired through user selection (open panel or
  drag-in), and
- **security-scoped bookmarks** for any persisted workspace URLs (favorites,
  saved workspaces, recent locations), created with
  `bookmarkData(options: .withSecurityScope)` and re-resolved with
  `startAccessingSecurityScopedResource()` on launch.

## Build configurations

- **Debug** — unsigned (ad-hoc identity `-`), Hardened Runtime disabled. This
  keeps local development and CI friction-free; CI builds with
  `CODE_SIGNING_ALLOWED=NO`.
- **Release** — Hardened Runtime enabled, manual signing with the
  `Developer ID Application` identity, for both the app and the embedded
  `mfd` helper CLI. App Sandbox stays off in both configurations.

The ad-hoc release script overrides the Release signing identity while
building, then explicitly signs `Contents/Helpers/mfd` followed by the app.
It does not change the checked-in Xcode project or the Developer ID path.

Opening Terminal, iTerm2, or Warp uses the system `open` command. The app does
not request Apple Events automation access or control those applications with
AppleScript.

## Automated release without a certificate

To build the same package locally, run:

```sh
scripts/build-adhoc-release.sh
```

The script uses the checked-in `MultiFinder.xcodeproj` and:

1. builds Release with `ARCHS="arm64 x86_64"` and `ONLY_ACTIVE_ARCH=NO`,
2. verifies both slices in the app executable and embedded `mfd`,
3. applies ad-hoc signatures to `mfd` and then `MultiFinder.app`,
4. verifies the signatures and repeats all checks after a ZIP round trip, and
5. writes `build/release/MultiFinder.zip` and
   `build/release/MultiFinder.zip.sha256`.

To publish, create and push a tag whose name starts with `v`:

```sh
git tag v1.0.0
git push origin v1.0.0
```

`.github/workflows/release.yml` builds on GitHub's macOS runner, creates or
updates the Release for that tag, and uploads both files. It needs only the
workflow's built-in `contents: write` permission; no signing secrets are used.

The generated `MultiFinder.zip` is the installable binary. GitHub also adds
`Source code (zip)` and `Source code (tar.gz)` automatically, but those contain
source code and are not application installers.

Because the automated build is not Apple-notarized, users must explicitly
allow its first launch. See the [Chinese installation and verification
instructions](UNNOTARIZED_RELEASE.md), which are also used as the GitHub
Release notes.

## Developer ID one-time setup

1. **Developer ID certificate** — in your Apple Developer account (or via
   Xcode's Settings > Accounts > Manage Certificates), create a
   **Developer ID Application** certificate and install it in your login
   keychain.

2. **Team ID** — copy the tracked example and fill in your Team ID (found on
   the Apple Developer membership page):

   ```sh
   cp Signing.local.xcconfig.example Signing.local.xcconfig
   # edit Signing.local.xcconfig: DEVELOPMENT_TEAM = ABCDE12345
   ```

   `Signing.local.xcconfig` is gitignored; the tracked
   `Signing.release.xcconfig` includes it optionally, so the repository still
   builds (unsigned) for anyone without it. Alternatively, export
   `DEVELOPMENT_TEAM` in the environment when running the release script.

3. **Notarization credentials** — store an app-specific password as a
   notarytool keychain profile:

   ```sh
   xcrun notarytool store-credentials multifinder-notary \
       --apple-id you@example.com --team-id ABCDE12345
   ```

## Cutting a Developer ID release

```sh
NOTARY_PROFILE=multifinder-notary scripts/release.sh
```

The script fails fast if `DEVELOPMENT_TEAM` or `NOTARY_PROFILE` is missing,
then:

1. regenerates the Xcode project with `xcodegen generate`,
2. archives the Release configuration with `xcodebuild archive`,
3. exports a Developer ID-signed app using `scripts/ExportOptions.plist`,
4. zips the app with `ditto`,
5. submits it with `xcrun notarytool submit --wait`,
6. staples the ticket with `xcrun stapler staple`, and
7. re-zips the stapled app and prints the final artifact paths under
   `build/release/`.

Distribute `build/release/MultiFinder.zip`.
