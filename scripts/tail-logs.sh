#!/usr/bin/env bash
# Stream voxline's OSLog output to the terminal while the app runs.
#
# Usage:
#   scripts/tail-logs.sh                       # all categories, info+ level
#   scripts/tail-logs.sh pipeline llm          # filter to one or more categories
#   scripts/tail-logs.sh --debug               # include debug-level messages
#   scripts/tail-logs.sh --debug pipeline      # combine
#   scripts/tail-logs.sh --last 5m             # replay the last 5 minutes, then stream
#   scripts/tail-logs.sh --raw                 # disable reformatting/colors (raw `log` output)
#
# Known categories (see voxline/Diagnostics/AppLog.swift):
#   pipeline, hotkey, audio, whisper, llm, paste, context, permissions, keychain
#
# Notes:
#   - `log stream` requires admin/dev privileges for the --level flag; macOS will
#     prompt the first time. No sudo required.
#   - Stop with Ctrl-C.
#   - Output is reformatted by default: date stripped, PID/TID dropped,
#     subsystem prefix removed, category column padded, and level/category
#     colorized when stdout is a TTY. Pass --raw or pipe to a file to disable.

set -euo pipefail

SUBSYSTEM="com.voxline.app"
LEVEL="info"
LAST=""
RAW=0
CATEGORIES=()

while (( $# )); do
    case "$1" in
        --debug)
            LEVEL="debug"
            shift
            ;;
        --last)
            LAST="${2:-}"
            if [[ -z "$LAST" ]]; then
                echo "error: --last requires a duration (e.g. 5m, 1h)" >&2
                exit 2
            fi
            shift 2
            ;;
        --raw)
            RAW=1
            shift
            ;;
        -h|--help)
            sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --*)
            echo "error: unknown flag $1" >&2
            exit 2
            ;;
        *)
            CATEGORIES+=("$1")
            shift
            ;;
    esac
done

COLOR=0
if [[ $RAW -eq 0 && -t 1 ]]; then
    COLOR=1
fi

format_output() {
    if [[ $RAW -eq 1 ]]; then
        cat
        return
    fi
    awk -v color="$COLOR" '
        BEGIN {
            if (color) {
                RST="\033[0m"; DIM="\033[2m"; BOLD="\033[1m"
                RED="\033[31m"; GRN="\033[32m"; YEL="\033[33m"
                BLU="\033[34m"; MAG="\033[35m"; CYN="\033[36m"
                GRY="\033[90m"
            }
            cat_c["pipeline"]           = GRN
            cat_c["hotkey"]             = BLU
            cat_c["audio"]              = CYN
            cat_c["whisper"]            = MAG
            cat_c["llm"]                = YEL
            cat_c["paste"]              = BLU
            cat_c["context"]            = GRY
            cat_c["permissions"]        = GRY
            cat_c["keychain"]           = GRY
            cat_c["keychain-migration"] = GRY
        }
        # drop the `log show` header
        /^Timestamp[[:space:]]+Ty/ { next }
        # pass through banners we emit ourselves
        /^# / { print; fflush(); next }
        /^[[:space:]]*$/ { print; fflush(); next }
        {
            line = $0
            if (line !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2} /) { print; fflush(); next }

            # HH:MM:SS.mmm sits at columns 12..23 in compact format
            t = substr(line, 12, 12)
            rest = substr(line, 25)
            sub(/^ +/, "", rest)

            # type code (Df, I, Db, E, F, ...)
            n = index(rest, " ")
            if (n == 0) { print line; fflush(); next }
            ty = substr(rest, 1, n - 1)
            rest = substr(rest, n + 1)
            sub(/^ +/, "", rest)

            # drop process[pid:tid]
            sub(/^[^[]*\[[0-9]+:[0-9a-f]+\] +/, "", rest)

            # extract [com.voxline.app:CATEGORY]
            cat = "?"
            if (sub(/^\[com\.voxline\.app:/, "", rest)) {
                k = index(rest, "]")
                if (k > 0) {
                    cat = substr(rest, 1, k - 1)
                    rest = substr(rest, k + 1)
                    sub(/^ +/, "", rest)
                }
            }

            lvl = ""
            if (ty == "E" || ty == "Er")      lvl = RED
            else if (ty == "F" || ty == "Ft") lvl = RED BOLD
            else if (ty == "Db")              lvl = DIM

            cc = cat_c[cat]
            if (cc == "") cc = CYN

            printf "%s%s%s %s%-2s%s %s%-18s%s %s%s%s\n", \
                DIM, t, RST, \
                lvl, ty, RST, \
                cc, cat, RST, \
                lvl, rest, RST
            fflush()
        }
    '
}

PREDICATE="subsystem == \"$SUBSYSTEM\""
if (( ${#CATEGORIES[@]} )); then
    cat_clause=""
    for c in "${CATEGORIES[@]}"; do
        if [[ -n "$cat_clause" ]]; then
            cat_clause="$cat_clause OR "
        fi
        cat_clause="${cat_clause}category == \"$c\""
    done
    PREDICATE="$PREDICATE AND ($cat_clause)"
fi

echo "# tailing $SUBSYSTEM (level=$LEVEL${LAST:+, replay=$LAST})" >&2
echo "# predicate: $PREDICATE" >&2
echo "# Ctrl-C to stop" >&2
echo >&2

if [[ -n "$LAST" ]]; then
    log show --predicate "$PREDICATE" --info --debug --last "$LAST" --style compact 2>/dev/null | format_output || true
    echo >&2
    echo "# --- live stream begins ---" >&2
fi

log stream --predicate "$PREDICATE" --level "$LEVEL" --style compact | format_output
