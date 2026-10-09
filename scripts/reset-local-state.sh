#!/usr/bin/env bash
# Reset voxline local state so the next launch behaves like a brand-new install.
#
# Wipes:
#   - ~/Library/Application Support/voxline (custom modes, Whisper model cache)
#   - The com.voxline.app defaults domain (settings, history, first-run flag)
#   - ~/Library/Caches/com.voxline.app (ANE compiled bundle)
#   - Any leftover 0.3.x sandbox container Data/
#   - Keychain entries for Anthropic + OpenAI API keys
#   - Stray voxline-status-test-*.plist files from past test runs
#
# Preserves by default:
#   - The custom vocabulary list. Re-entering vocab on every reset is tedious;
#     pass --wipe-vocab to clear it too.
#
# Optional flags:
#   --keep-model      Preserve the cached Whisper model AND the ANE compiled
#                     bundle so the next launch doesn't re-download the model
#                     or pay the 30s-2min ANE recompile. Everything else
#                     (settings, history, keychain, etc.) is still wiped.
#   --wipe-vocab      Also wipe the custom vocabulary list (default is to
#                     preserve it across resets).
#   --reset-tcc       Also reset macOS privacy prompts (mic, accessibility,
#                     input monitoring) so the OS re-asks on next launch.
#   --reset-keys      Accepted for explicitness. Keychain clearing is part of
#                     the default behavior; this flag is a no-op.
#   -h, --help        Show this help.

set -euo pipefail

BUNDLE_ID="com.voxline.app"
KEYCHAIN_SERVICE="com.voxline.app.keys"
APP_SUPPORT="$HOME/Library/Application Support/voxline"
HF_MODEL_PATH="$APP_SUPPORT/huggingface"
CACHES_DIR="$HOME/Library/Caches/$BUNDLE_ID"
ANE_BUNDLE_PATH="$CACHES_DIR/com.apple.e5rt.e5bundlecache"
LEGACY_CONTAINER_DATA="$HOME/Library/Containers/$BUNDLE_ID/Data"
# plutil treats `.` in keypaths as nested-dict separators. The actual top-level
# UserDefaults key contains dots, so each one has to be backslash-escaped when
# passed to `plutil -extract`/`-insert`. Key must match CustomVocabularyStore.
VOCAB_KEY='voxline\.context\.customVocabulary'

KEEP_MODEL=0
RESET_TCC=0
KEEP_VOCAB=1

for arg in "$@"; do
    case "$arg" in
        --keep-model) KEEP_MODEL=1 ;;
        --wipe-vocab) KEEP_VOCAB=0 ;;
        --reset-tcc)  RESET_TCC=1 ;;
        --reset-keys) ;; # no-op; keychain clearing is part of the default flow
        -h|--help)
            sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown flag: $arg" >&2
            exit 2
            ;;
    esac
done

echo "→ Quitting voxline if running..."
osascript -e 'tell application "voxline" to quit' >/dev/null 2>&1 || true
sleep 1

# Stash the custom vocab before the wipe. `defaults export` goes through
# cfprefsd, so it sees the live domain rather than a possibly stale plist.
STASHED_VOCAB_PLIST=""
if [[ $KEEP_VOCAB -eq 1 ]]; then
    FULL_EXPORT=$(mktemp -t voxline-prefs).plist
    if defaults export "$BUNDLE_ID" "$FULL_EXPORT" 2>/dev/null; then
        STASHED_VOCAB_PLIST=$(mktemp -t voxline-vocab).plist
        if plutil -extract "$VOCAB_KEY" xml1 -o "$STASHED_VOCAB_PLIST" "$FULL_EXPORT" 2>/dev/null; then
            echo "→ Stashing custom vocabulary..."
        else
            rm -f "$STASHED_VOCAB_PLIST"
            STASHED_VOCAB_PLIST=""
            echo "→ No custom vocabulary to preserve."
        fi
    fi
    rm -f "$FULL_EXPORT"
fi

STASH=$(mktemp -d -t voxline-reset)
trap 'rm -rf "$STASH"' EXIT

if [[ $KEEP_MODEL -eq 1 ]]; then
    if [[ -d "$HF_MODEL_PATH" ]]; then
        echo "→ Stashing Whisper model cache..."
        mv "$HF_MODEL_PATH" "$STASH/huggingface"
    fi
    if [[ -d "$ANE_BUNDLE_PATH" ]]; then
        echo "→ Stashing ANE compiled-bundle cache..."
        mv "$ANE_BUNDLE_PATH" "$STASH/anebundle"
    fi
fi

echo "→ Clearing $APP_SUPPORT..."
rm -rf "$APP_SUPPORT"
echo "→ Clearing defaults domain $BUNDLE_ID..."
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
echo "→ Clearing $CACHES_DIR..."
rm -rf "$CACHES_DIR"

# NOTE: wipe the legacy container's Data/ contents, not the container itself.
# containermanagerd protects the container directory and its metadata plist.
if [[ -d "$LEGACY_CONTAINER_DATA" ]]; then
    echo "→ Clearing leftover 0.3.x sandbox container Data/..."
    rm -rf "$LEGACY_CONTAINER_DATA"/* "$LEGACY_CONTAINER_DATA"/.[!.]* 2>/dev/null || true
fi

if [[ -d "$STASH/huggingface" ]]; then
    echo "→ Restoring Whisper model cache..."
    mkdir -p "$(dirname "$HF_MODEL_PATH")"
    mv "$STASH/huggingface" "$HF_MODEL_PATH"
fi
if [[ -d "$STASH/anebundle" ]]; then
    echo "→ Restoring ANE compiled-bundle cache..."
    mkdir -p "$(dirname "$ANE_BUNDLE_PATH")"
    mv "$STASH/anebundle" "$ANE_BUNDLE_PATH"
fi

# Restore vocab after the wipe. The stashed file is a standalone plist whose
# root element IS the vocab value. Strip the <plist> wrapper, insert it into a
# fresh plist under the real key, and import that through cfprefsd.
if [[ -n "$STASHED_VOCAB_PLIST" && -f "$STASHED_VOCAB_PLIST" ]]; then
    echo "→ Restoring custom vocabulary..."
    IMPORT_PLIST=$(mktemp -t voxline-import).plist
    plutil -create xml1 "$IMPORT_PLIST"
    inner_xml=$(awk '
        /<plist/ { flag=1; next }
        /<\/plist>/ { flag=0 }
        flag { print }
    ' "$STASHED_VOCAB_PLIST")
    plutil -insert "$VOCAB_KEY" -xml "$inner_xml" "$IMPORT_PLIST"
    defaults import "$BUNDLE_ID" "$IMPORT_PLIST"
    rm -f "$STASHED_VOCAB_PLIST" "$IMPORT_PLIST"
fi

echo "→ Deleting Keychain entries (service=$KEYCHAIN_SERVICE)..."
# Data-protection keychain (where current builds write). The `security` CLI
# can't reach DPK items — they're gated by the app's keychain-access-groups
# entitlement. Drive deletion through the signed app binary itself.
binary_can_reach_dpk() {
    local bin=$1
    [[ -x "$bin" ]] || return 1
    local app=${bin%/Contents/MacOS/voxline}
    codesign --verify --deep --strict "$app" 2>/dev/null || return 1
    codesign -dv "$app" 2>&1 | grep -q "TeamIdentifier=2B5FBFV6CF" || return 1
    return 0
}
find_app_binary() {
    local candidates=(
        "/Applications/voxline.app/Contents/MacOS/voxline"
        "$HOME/Applications/voxline.app/Contents/MacOS/voxline"
    )
    local dd
    dd=$(ls -td "$HOME/Library/Developer/Xcode/DerivedData"/voxline-*/Build/Products/Debug/voxline.app/Contents/MacOS/voxline 2>/dev/null | head -1)
    [[ -n "$dd" ]] && candidates+=("$dd")

    local skipped=()
    for c in "${candidates[@]}"; do
        if binary_can_reach_dpk "$c"; then
            echo "$c"
            (( ${#skipped[@]} )) && printf '   ⚠ skipped (bad signature): %s\n' "${skipped[@]}" >&2
            return 0
        elif [[ -x "$c" ]]; then
            skipped+=("$c")
        fi
    done
    (( ${#skipped[@]} )) && printf '   ⚠ skipped (bad signature): %s\n' "${skipped[@]}" >&2
    return 1
}
if app_bin=$(find_app_binary); then
    echo "   invoking $app_bin --reset-keys for data-protection keychain..."
    "$app_bin" --reset-keys 2>&1 | sed 's/^/   /'
else
    echo "   ⚠ no built voxline binary found — data-protection keychain entries"
    echo "     were NOT cleared. Build the app first, or remove items with service"
    echo "     '$KEYCHAIN_SERVICE' in Keychain Access by hand."
fi

echo "→ Cleaning stray voxline-status-test-*.plist files..."
shopt -s nullglob
stale=( "$HOME"/Library/Preferences/voxline-status-test-*.plist )
if (( ${#stale[@]} )); then
    rm -f "${stale[@]}"
    echo "   removed ${#stale[@]} file(s)."
else
    echo "   none found."
fi

if [[ $RESET_TCC -eq 1 ]]; then
    if [[ -z "${BUNDLE_ID:-}" ]]; then
        echo "✗ refusing to run --reset-tcc: BUNDLE_ID is empty." >&2
        exit 3
    fi
    echo "→ Resetting TCC privacy prompts for $BUNDLE_ID only..."
    for svc in Microphone ListenEvent Accessibility; do
        if tccutil reset "$svc" "$BUNDLE_ID" >/dev/null 2>&1; then
            echo "   reset:   $svc"
        else
            echo "   absent:  $svc (no entry for $BUNDLE_ID, or service name not recognized)"
        fi
    done
fi

echo "✓ Done. Next launch will run the first-run wizard."
