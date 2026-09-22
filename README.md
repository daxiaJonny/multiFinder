# MultiFinder

MultiFinder is a multi-pane file manager for macOS 14 and later. The checked-in `project.yml` is the project configuration source; regenerate `MultiFinder.xcodeproj` after changing targets or build settings.

## Build and test

Requirements: Xcode 16 and XcodeGen.

```sh
xcodegen generate
xcodebuild -project MultiFinder.xcodeproj -scheme MultiFinder -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -project MultiFinder.xcodeproj -scheme MultiFinder -configuration Debug CODE_SIGNING_ALLOWED=NO test
```

The app uses virtualized AppKit tables and collections for file views. Browser locations explicitly distinguish directories, Recents, and Spotlight searches. A toolbar star stores frequently used folders in the shared sidebar favorites list. File mutations run through a serial background operation queue with conflict resolution, progress, cancellation, retry history, and undo/redo.

The toolbar keeps file search, read-only folder questions, and AI organization as separate actions. Search uses Spotlight. Folder questions use the local Cursor CLI in `ask` mode and can be opened with Option-Command-A. AI organization uses a validated, previewable operation plan and never changes files before confirmation.

## Terminal integration

`mfd [path]` opens a local path using the existing pane routing. `mfd --new-tab [path]`
creates a tab in the focused pane, preserving existing tabs. Both default to the
working directory; a file or package passed with `--new-tab` is selected in its
enclosing folder. Paths with spaces can be quoted, and `--` ends option parsing.

```sh
mfd --new-tab ~/Downloads
mfd --new-tab "./report draft.txt"
mfd --new-tab -- ./-notes
```

The URL equivalent is `multifinder://open?path=/absolute/path&newTab=true`.

## Performance checks

Directory names are prepared and sorted off the main actor before metadata is
loaded. Refreshes reuse known metadata, and cancelled loads stop their background
workers. `FileBrowserPerformanceTests` records natural sorting and progressive
loading for 10,000 files; timings depend on the machine, filesystem cache, and
build configuration. Run this subset with:

```sh
xcodebuild -project MultiFinder.xcodeproj -scheme MultiFinder -configuration Debug CODE_SIGNING_ALLOWED=NO -only-testing:MultiFinderTests/FileBrowserPerformanceTests test
```

## Distribution

Pushing a `v*` tag runs the GitHub Release workflow. It builds an
`arm64+x86_64` Universal app, applies ad-hoc signatures to the app and embedded
`mfd` helper, verifies both architecture slices and signatures, and uploads
these files to the matching GitHub Release:

- `MultiFinder.zip` - the compiled app for users, not GitHub's source-code ZIP
- `MultiFinder.zip.sha256` - the SHA-256 checksum

The automated package requires no Apple certificate, but it is not notarized.
首次打开被 macOS 阻止时，请按[中文安装说明](docs/UNNOTARIZED_RELEASE.md)前往
“系统设置” -> “隐私与安全性” -> “仍要打开”。A local build of the same
package can be created with:

```sh
scripts/build-adhoc-release.sh
```

MultiFinder also supports Developer ID independent distribution with Hardened
Runtime and notarization. It is not an App Store app because App Sandbox would
break browsing arbitrary filesystem locations, the app's core feature. To
build, notarize, and staple a Developer ID release:

```sh
NOTARY_PROFILE=<your-notarytool-profile> scripts/release.sh
```

See [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) for both release paths,
Developer ID setup, the entitlement rationale, and what an App Store build
would require if the decision were ever revisited.
