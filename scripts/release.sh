#!/bin/bash
# Builds, signs, notarizes, and staples a Developer ID release of MultiFinder.
# See docs/DISTRIBUTION.md for one-time setup.
#
# Requires:
#   DEVELOPMENT_TEAM  - Apple Team ID, from the environment or Signing.local.xcconfig
#   NOTARY_PROFILE    - notarytool keychain profile name
#                       (created with: xcrun notarytool store-credentials)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

fail() { echo "error: $*" >&2; exit 1; }

# Resolve DEVELOPMENT_TEAM from the environment or Signing.local.xcconfig.
if [[ -z "${DEVELOPMENT_TEAM:-}" && -f Signing.local.xcconfig ]]; then
    DEVELOPMENT_TEAM="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*//p' Signing.local.xcconfig | head -1 | tr -d '[:space:]')"
fi
[[ -n "${DEVELOPMENT_TEAM:-}" && "$DEVELOPMENT_TEAM" != "YOUR_TEAM_ID" ]] || fail "DEVELOPMENT_TEAM is not set.
Set it in the environment, or copy Signing.local.xcconfig.example to Signing.local.xcconfig and fill in your Team ID."

[[ -n "${NOTARY_PROFILE:-}" ]] || fail "NOTARY_PROFILE is not set.
Create a profile with: xcrun notarytool store-credentials <name> --apple-id <id> --team-id $DEVELOPMENT_TEAM
then run: NOTARY_PROFILE=<name> scripts/release.sh"

OUT_DIR="$REPO_ROOT/build/release"
ARCHIVE_PATH="$OUT_DIR/MultiFinder.xcarchive"
EXPORT_PATH="$OUT_DIR/export"
APP_PATH="$EXPORT_PATH/MultiFinder.app"
ZIP_PATH="$OUT_DIR/MultiFinder.zip"
rm -rf "$OUT_DIR"

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Archiving Release build (team $DEVELOPMENT_TEAM)"
xcodebuild \
    -project MultiFinder.xcodeproj \
    -scheme MultiFinder \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    archive

echo "==> Exporting Developer ID app"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist scripts/ExportOptions.plist \
    -exportPath "$EXPORT_PATH" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
[[ -d "$APP_PATH" ]] || fail "export did not produce $APP_PATH"

echo "==> Zipping app for notarization"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Submitting to Apple notary service (this can take a few minutes)"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP_PATH"

echo "==> Zipping stapled app"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Done."
echo "App:     $APP_PATH"
echo "Archive: $ZIP_PATH"
