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

## Distribution

The development build intentionally runs without App Sandbox so it can browse arbitrary filesystem locations. Hardened Runtime is also disabled in `project.yml`; this is not a release configuration.

Before independent distribution, add Developer ID signing, enable Hardened Runtime, and notarize the app. An App Store build instead requires App Sandbox, user-selected directory access, and persistent security-scoped bookmarks. Make that distribution choice before storing production workspace URLs.
