#!/bin/bash
# Build an ad-hoc-signed Universal release without Apple Developer credentials.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
BUILD_ROOT="$REPO_ROOT/build"
PROJECT_PATH="$REPO_ROOT/MultiFinder.xcodeproj"
ENTITLEMENTS_PATH="$REPO_ROOT/MultiFinder/MultiFinder.entitlements"

fail() {
    echo "error: $*" >&2
    exit 1
}

log() {
    echo "==> $*"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

reset_generated_directory() {
    local path="$1"
    local expected="$2"

    remove_generated_directory "$path" "$expected"
    mkdir -p -- "$path"
}

remove_generated_directory() {
    local path="$1"
    local expected="$2"

    [[ -n "$path" && "$path" == "$expected" ]] || fail "refusing to reset unexpected path: $path"
    [[ "$path" == "$BUILD_ROOT"/* ]] || fail "generated path is outside $BUILD_ROOT: $path"
    [[ "$path" != "$BUILD_ROOT" && "$path" != "$REPO_ROOT" && "$path" != "/" ]] || \
        fail "refusing to reset unsafe path: $path"

    rm -rf -- "$path"
}

cleanup_generated_directories() {
    local exit_status="$?"

    trap - EXIT
    set +e
    if [[ -e "$WORK_DIR" ]]; then
        remove_generated_directory "$WORK_DIR" "$BUILD_ROOT/adhoc-release-work"
    fi
    if [[ "$exit_status" -ne 0 && -e "$OUTPUT_DIR" ]]; then
        remove_generated_directory "$OUTPUT_DIR" "$BUILD_ROOT/release"
    fi
    if [[ -d "$LOCK_DIR" ]]; then
        rmdir -- "$LOCK_DIR"
    fi
    exit "$exit_status"
}

acquire_build_lock() {
    if ! mkdir -- "$LOCK_DIR"; then
        fail "another ad-hoc release build is already using $BUILD_ROOT"
    fi
}

verify_universal_binary() {
    local binary="$1"
    local architectures
    local architecture_count

    [[ -f "$binary" ]] || fail "expected executable is missing: $binary"
    architectures="$(lipo -archs "$binary")" || fail "could not inspect architectures: $binary"
    lipo "$binary" -verify_arch arm64 x86_64 >/dev/null || \
        fail "executable is not arm64+x86_64 Universal: $binary ($architectures)"

    architecture_count="$(printf '%s\n' "$architectures" | awk '{ print NF }')"
    [[ "$architecture_count" == "2" ]] || \
        fail "expected exactly two architectures in $binary, found: $architectures"
    case " $architectures " in
        *" arm64 "*) ;;
        *) fail "arm64 slice is missing from $binary: $architectures" ;;
    esac
    case " $architectures " in
        *" x86_64 "*) ;;
        *) fail "x86_64 slice is missing from $binary: $architectures" ;;
    esac

    echo "verified Universal binary: $binary ($architectures)"
}

verify_adhoc_signature() {
    local target="$1"
    local signature_details

    codesign --verify --strict --verbose=2 "$target"
    signature_details="$(codesign --display --verbose=4 "$target" 2>&1)" || \
        fail "could not inspect code signature: $target"
    grep -q '^Signature=adhoc$' <<< "$signature_details" || \
        fail "expected an ad-hoc signature: $target"

    echo "verified ad-hoc signature: $target"
}

verify_app_bundle() {
    local app="$1"
    local info_plist="$app/Contents/Info.plist"
    local executable_name
    local app_executable
    local helper_executable="$app/Contents/Helpers/mfd"

    [[ -d "$app" ]] || fail "app bundle is missing: $app"
    [[ -f "$info_plist" ]] || fail "Info.plist is missing: $info_plist"

    executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")" || \
        fail "CFBundleExecutable is missing from $info_plist"
    [[ -n "$executable_name" && "$executable_name" != */* && "$executable_name" != .* ]] || \
        fail "unsafe CFBundleExecutable value: $executable_name"

    app_executable="$app/Contents/MacOS/$executable_name"
    verify_universal_binary "$app_executable"
    verify_universal_binary "$helper_executable"
    verify_adhoc_signature "$helper_executable"
    codesign --verify --deep --strict --verbose=2 "$app"
    verify_adhoc_signature "$app"
}

for command_name in awk codesign ditto grep lipo shasum xcodebuild; do
    require_command "$command_name"
done
[[ -x /usr/libexec/PlistBuddy ]] || fail "required command not found: /usr/libexec/PlistBuddy"
[[ -d "$PROJECT_PATH" ]] || fail "Xcode project is missing: $PROJECT_PATH"
[[ -f "$PROJECT_PATH/project.pbxproj" ]] || fail "project.pbxproj is missing: $PROJECT_PATH/project.pbxproj"
[[ -f "$ENTITLEMENTS_PATH" ]] || fail "entitlements file is missing: $ENTITLEMENTS_PATH"

EXPECTED_BUILD_ROOT="$REPO_ROOT/build"
mkdir -p -- "$EXPECTED_BUILD_ROOT"
BUILD_ROOT="$(cd "$EXPECTED_BUILD_ROOT" && pwd -P)"
[[ "$BUILD_ROOT" == "$EXPECTED_BUILD_ROOT" ]] || \
    fail "build directory resolves outside the repository: $EXPECTED_BUILD_ROOT -> $BUILD_ROOT"
WORK_DIR="$BUILD_ROOT/adhoc-release-work"
OUTPUT_DIR="$BUILD_ROOT/release"
LOCK_DIR="$BUILD_ROOT/adhoc-release.lock"
DERIVED_DATA="$WORK_DIR/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Release/MultiFinder.app"
ZIP_PATH="$OUTPUT_DIR/MultiFinder.zip"
CHECKSUM_PATH="$OUTPUT_DIR/MultiFinder.zip.sha256"

acquire_build_lock
trap cleanup_generated_directories EXIT
reset_generated_directory "$WORK_DIR" "$BUILD_ROOT/adhoc-release-work"
reset_generated_directory "$OUTPUT_DIR" "$BUILD_ROOT/release"

log "Building arm64+x86_64 Release without Developer ID signing"
xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme MultiFinder \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS='arm64 x86_64' \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY='' \
    DEVELOPMENT_TEAM='' \
    build

[[ -d "$APP_PATH" ]] || fail "build did not produce $APP_PATH"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/MultiFinder"
HELPER_EXECUTABLE="$APP_PATH/Contents/Helpers/mfd"
verify_universal_binary "$APP_EXECUTABLE"
verify_universal_binary "$HELPER_EXECUTABLE"

log "Applying ad-hoc signatures"
codesign --force --sign - --timestamp=none --options runtime "$HELPER_EXECUTABLE"
codesign \
    --force \
    --sign - \
    --timestamp=none \
    --options runtime \
    --entitlements "$ENTITLEMENTS_PATH" \
    "$APP_PATH"
verify_app_bundle "$APP_PATH"

log "Creating MultiFinder.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
[[ -s "$ZIP_PATH" ]] || fail "archive was not created: $ZIP_PATH"

log "Verifying the packaged app after extraction"
VERIFY_DIR="$WORK_DIR/package-verification"
mkdir -p -- "$VERIFY_DIR"
ditto -x -k "$ZIP_PATH" "$VERIFY_DIR"
verify_app_bundle "$VERIFY_DIR/MultiFinder.app"

log "Writing and verifying SHA-256 checksum"
(
    cd "$OUTPUT_DIR"
    shasum -a 256 MultiFinder.zip > MultiFinder.zip.sha256
    shasum -a 256 -c MultiFinder.zip.sha256
)
[[ -s "$CHECKSUM_PATH" ]] || fail "checksum was not created: $CHECKSUM_PATH"

echo
echo "Release artifacts:"
echo "  $ZIP_PATH"
echo "  $CHECKSUM_PATH"
echo "This build is ad-hoc signed and is not notarized by Apple."
