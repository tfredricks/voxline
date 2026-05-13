#!/usr/bin/env bash
# Reset voxline local state so the next launch behaves like a brand-new install.
#
# Wipes:
#   - Sandbox container (UserDefaults incl. hasCompletedFirstRun, custom
#     modes/vocab, history, logs, caches)
#   - Keychain entries for Anthropic + OpenAI API keys
#   - Stray voxline-status-test-*.plist files from past test runs
#
# Optional flags:
#   --keep-model      Preserve the cached Whisper model AND the ANE compiled
#                     bundle so the next launch doesn't re-download the model
#                     or pay the 30s-2min ANE recompile. Everything else
#                     (settings, history, keychain, etc.) is still wiped.
#   --reset-tcc       Also reset macOS privacy prompts (mic, accessibility,
#                     input monitoring) so the OS re-asks on next launch.
#   --reset-keys      Accepted for explicitness. Keychain clearing is part of
#                     the default behavior; this flag is a no-op.
#   -h, --help        Show this help.

set -euo pipefail

BUNDLE_ID="com.voxline.app"
KEYCHAIN_SERVICE="com.voxline.app.keys"
CONTAINER="$HOME/Library/Containers/$BUNDLE_ID"
DATA_DIR="$CONTAINER/Data"
# Paths to preserve when --keep-model is set. Both live INSIDE the sandbox
# container, not under ~/Documents (see voxline.entitlements: app-sandbox=true).
HF_MODEL_PATH="$DATA_DIR/Documents/huggingface"
ANE_BUNDLE_PATH="$DATA_DIR/Library/Caches/$BUNDLE_ID/com.apple.e5rt.e5bundlecache"

KEEP_MODEL=0
RESET_TCC=0

for arg in "$@"; do
    case "$arg" in
        --keep-model) KEEP_MODEL=1 ;;
        --reset-tcc)  RESET_TCC=1 ;;
        --reset-keys) ;; # no-op; keychain clearing is part of the default flow
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
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
# Give the app a moment to flush prefs before we delete them.
sleep 1

# NOTE: wipe $DATA_DIR contents, not $CONTAINER itself. containermanagerd
# protects the container directory and its metadata plist, so a full
# `rm -rf $CONTAINER` fails with EPERM. Everything app-owned lives under Data/.
if [[ ! -d "$DATA_DIR" ]]; then
    echo "→ No sandbox container Data/ found — already clean."
elif [[ $KEEP_MODEL -eq 1 ]]; then
    # Stash → wipe → restore. Doing a selective find/prune is fragile because
    # rm -rf'ing a parent kills its preserved children. Move-out, nuke-all,
    # move-back is the simplest correct pattern.
    STASH=$(mktemp -d -t voxline-reset)
    trap 'rm -rf "$STASH"' EXIT

    stashed_any=0
    if [[ -d "$HF_MODEL_PATH" ]]; then
        echo "→ Stashing Whisper model cache..."
        mv "$HF_MODEL_PATH" "$STASH/huggingface"
        stashed_any=1
    fi
    if [[ -d "$ANE_BUNDLE_PATH" ]]; then
        echo "→ Stashing ANE compiled-bundle cache..."
        mv "$ANE_BUNDLE_PATH" "$STASH/anebundle"
        stashed_any=1
    fi
    if [[ $stashed_any -eq 0 ]]; then
        echo "→ Nothing to preserve (no model or ANE cache present) — wiping all of Data/."
    fi

    echo "→ Clearing sandbox container Data/ at $DATA_DIR..."
    rm -rf "$DATA_DIR"/* "$DATA_DIR"/.[!.]* 2>/dev/null || true

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
else
    echo "→ Clearing sandbox container Data/ at $DATA_DIR (model included)..."
    rm -rf "$DATA_DIR"/* "$DATA_DIR"/.[!.]* 2>/dev/null || true
fi

echo "→ Deleting Keychain entries (service=$KEYCHAIN_SERVICE)..."
# Legacy file keychain (covers older builds that wrote here).
for account in anthropic openai; do
    if security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$account" >/dev/null 2>&1; then
        echo "   removed (legacy): $account"
    fi
done
# Data-protection keychain (where current builds write). The `security` CLI
# can't reach DPK items — they're gated by the app's keychain-access-groups
# entitlement. Drive deletion through the signed app binary itself.
find_app_binary() {
    local candidates=(
        "/Applications/voxline.app/Contents/MacOS/voxline"
        "$HOME/Applications/voxline.app/Contents/MacOS/voxline"
    )
    for c in "${candidates[@]}"; do
        [[ -x "$c" ]] && { echo "$c"; return 0; }
    done
    # Fall back to most recent DerivedData Debug build.
    local dd
    dd=$(ls -td "$HOME/Library/Developer/Xcode/DerivedData"/voxline-*/Build/Products/Debug/voxline.app/Contents/MacOS/voxline 2>/dev/null | head -1)
    [[ -n "$dd" && -x "$dd" ]] && { echo "$dd"; return 0; }
    return 1
}
if app_bin=$(find_app_binary); then
    echo "   invoking $app_bin --reset-keys for data-protection keychain..."
    "$app_bin" --reset-keys 2>&1 | sed 's/^/   /'
else
    echo "   ⚠ no built voxline binary found — data-protection keychain entries"
    echo "     (the ones current builds use) were NOT cleared. Either build the"
    echo "     app first, or open Keychain Access and remove items with service"
    echo "     '$KEYCHAIN_SERVICE' by hand."
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
    # Safety guard: tccutil reset WITHOUT a bundle id wipes the service
    # system-wide for every app on the machine. Refuse to proceed if
    # BUNDLE_ID is somehow empty so a future edit can't silently turn this
    # block back into a system-wide nuke.
    if [[ -z "${BUNDLE_ID:-}" ]]; then
        echo "✗ refusing to run --reset-tcc: BUNDLE_ID is empty." >&2
        echo "  A bare 'tccutil reset <Service>' resets that service for ALL apps." >&2
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
