#!/usr/bin/env bash
# Render text lines to speech with `say` for engine bake-off smoke runs.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: scripts/make-synthetic-bakeoff.sh <lines.txt> <outdir>

Renders each non-empty line of <lines.txt> to <outdir>/clip-NN.wav (16 kHz
mono Float32) with a matching clip-NN.txt reference, rotating through the
voices Samantha, Daniel, Karen, Moira, and Tessa. Voices that `say -v '?'`
does not list are skipped.

Existing clip-*.wav and clip-*.txt files in <outdir> are removed first.

Add a terms.txt (one dictionary term per line) to <outdir>, then run:
  TEST_RUNNER_VOXLINE_BAKEOFF=1 TEST_RUNNER_VOXLINE_BAKEOFF_DIR=<outdir> xcodebuild test \
    -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' \
    -only-testing:voxlineTests/EngineBakeoffTests
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

if [[ $# -ne 2 ]]; then
    usage >&2
    exit 2
fi

lines_file=$1
out=$2

if [[ ! -f "$lines_file" ]]; then
    echo "error: $lines_file not found" >&2
    exit 1
fi

installed=$(say -v '?')
voices=()
for candidate in Samantha Daniel Karen Moira Tessa; do
    if grep -Eq "^${candidate}[[:space:]]" <<<"$installed"; then
        voices+=("$candidate")
    fi
done

if [[ ${#voices[@]} -eq 0 ]]; then
    echo "error: none of Samantha, Daniel, Karen, Moira, Tessa is installed" >&2
    exit 1
fi

mkdir -p "$out"
rm -f "$out"/clip-*.wav "$out"/clip-*.txt

count=0
while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line//$'\r'/}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [[ -z "$line" ]] && continue

    voice=${voices[count % ${#voices[@]}]}
    count=$((count + 1))
    name=$(printf 'clip-%02d' "$count")

    printf '%s\n' "$line" >"$out/$name.txt"
    say -v "$voice" -o "$out/$name.wav" --data-format=LEF32@16000 -f "$out/$name.txt"
done <"$lines_file"

echo "Wrote $count clips to $out"
