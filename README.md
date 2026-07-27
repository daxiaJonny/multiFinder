# MultiFinder

MultiFinder is a multi-pane file manager for macOS 14 and later. The checked-in `project.yml` is the project configuration source; regenerate `MultiFinder.xcodeproj` after changing targets or build settings.

## Build and test

Requirements: Xcode 16 and XcodeGen.

```sh
xcodegen generate
xcodebuild -project MultiFinder.xcodeproj -scheme MultiFinder -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -project MultiFinder.xcodeproj -scheme MultiFinder -configuration Debug CODE_SIGNING_ALLOWED=NO test
```

The app uses native SwiftUI tables for keyboard and accessibility behavior. Browser locations explicitly distinguish directories, Recents, and Spotlight searches. A toolbar star stores frequently used folders in the shared sidebar favorites list. File mutations run through a serial background operation queue with conflict resolution, progress, cancellation, retry history, and undo/redo.

The toolbar keeps file search, read-only folder questions, and AI organization as separate actions. Search uses Spotlight. Folder questions use the local Cursor CLI in `ask` mode and can be opened with Option-Command-A. AI organization uses a validated, previewable operation plan and never changes files before confirmation.

## Distribution

MultiFinder ships via Developer ID independent distribution with Hardened Runtime and notarization — not the App Store, because App Sandbox would break browsing arbitrary filesystem locations, the app's core feature. Debug builds stay unsigned with Hardened Runtime disabled for development convenience; the Release configuration enables Hardened Runtime and manual Developer ID signing, with the team ID supplied by an untracked `Signing.local.xcconfig` (copy `Signing.local.xcconfig.example`) or the `DEVELOPMENT_TEAM` environment variable.

To build, notarize, and staple a release:

```sh
NOTARY_PROFILE=<your-notarytool-profile> scripts/release.sh
```

See [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) for one-time setup (Developer ID certificate, notarytool credentials, xcconfig), the entitlement rationale, and what an App Store build would require if the decision were ever revisited.
