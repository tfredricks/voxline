#!/usr/bin/env bash
# Build voxline locally and install to /Applications.
#
# No paid Developer Program required. Uses whatever signing identity is
# configured in the .xcodeproj (typically a free "Apple Development"
# certificate tied to your Apple ID — set under Signing & Capabilities).
#
# Flags:
#   --debug      Build the Debug configuration instead of Release.
#   --no-install Build only; don't copy to /Applications.
#   -h, --help   Show this help.

set -euo pipefail

CONFIG="Release"
INSTALL=1

for arg in "$@"; do
    case "$arg" in
        --debug)      CONFIG="Debug" ;;
        --no-install) INSTALL=0 ;;
        -h|--help)
            sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown flag: $arg" >&2
            exit 2
            ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DERIVED="$REPO_ROOT/.build-local"
mkdir -p "$DERIVED"

# Stamp version metadata from git so the built bundle reflects the commit
# being built. CFBundleVersion is the commit count on the current branch
# (monotonic, numeric — what App Store / Sparkle expect). GitCommit is
# the short SHA, with "-dirty" appended when the working tree has
# uncommitted changes — lets you tell which build a binary actually came
# from when CFBundleVersion alone is ambiguous.
BUILD_NUMBER=$(git rev-list --count HEAD)
GIT_COMMIT=$(git rev-parse --short HEAD)
if ! git diff-index --quiet HEAD --; then
    GIT_COMMIT="${GIT_COMMIT}-dirty"
fi

echo "==> Building voxline ($CONFIG, build $BUILD_NUMBER, $GIT_COMMIT)..."
XCBUILD_ARGS=(
    -project voxline.xcodeproj
    -scheme voxline
    -configuration "$CONFIG"
    -destination 'platform=macOS'
    -derivedDataPath "$DERIVED"
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
    GIT_COMMIT="$GIT_COMMIT"
    build
)
xcodebuild "${XCBUILD_ARGS[@]}" | xcbeautify 2>/dev/null || xcodebuild "${XCBUILD_ARGS[@]}"

APP="$DERIVED/Build/Products/$CONFIG/voxline.app"
if [[ ! -d "$APP" ]]; then
    echo "Build produced no app at $APP" >&2
    exit 1
fi

if [[ "$INSTALL" -eq 0 ]]; then
    echo "==> Built: $APP"
    exit 0
fi

echo "==> Quitting any running voxline instance..."
osascript -e 'tell application "voxline" to quit' >/dev/null 2>&1 || true
# Give it a moment to release file locks before we replace the bundle.
for _ in 1 2 3 4 5; do
    pgrep -x voxline >/dev/null 2>&1 || break
    sleep 0.2
done

DEST="/Applications/voxline.app"
echo "==> Installing to ${DEST}..."
rm -rf "$DEST"
cp -R "$APP" "$DEST"

PLIST="$DEST/Contents/Info.plist"
SHORT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
SHA=$(/usr/libexec/PlistBuddy -c "Print :GitCommit" "$PLIST")
echo "==> Installed voxline $SHORT ($BUILD, $SHA). Launch with: open -a voxline"
