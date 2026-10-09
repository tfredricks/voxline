#!/usr/bin/env bash
# Render a two-voice synthetic conversation with `say` for meeting tests.
# Writes one 16 kHz WAV per turn, named so lexical order is speaking order.
#
# Usage: scripts/make-meeting-fixture.sh <out-dir> [turns]
set -euo pipefail

out="${1:?usage: $0 <out-dir> [turns]}"
turns="${2:-12}"
mkdir -p "$out"

voices=(Samantha Daniel)
lines=(
    "Thanks for joining. Let's go through the pricing proposal for Acme first."
    "Sure. They asked for a ten percent discount if they commit to two years."
    "I think we can do eight percent, but only with annual prepayment."
    "That works for me. Who will send them the revised quote?"
    "I'll send the revised quote by Friday."
    "Great. Next item is the onboarding timeline for their team."
    "They want to start the first week of November with forty seats."
    "Can we confirm the seat count before we schedule the kickoff?"
    "I'll confirm the seat count with their procurement lead tomorrow."
    "Good. Any open questions before we wrap up?"
    "Only whether they need single sign-on in the first phase."
    "Let's ask them on the next call. Thanks, everyone."
)

for ((i = 0; i < turns; i++)); do
    voice=${voices[i % 2]}
    line=${lines[i % ${#lines[@]}]}
    say -v "$voice" --file-format=WAVE --data-format=LEI16@16000 \
        -o "$out/$(printf '%02d' "$i")-$voice.wav" "$line"
done
echo "Wrote $turns turns to $out"
