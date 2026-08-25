#!/usr/bin/env bash
#
# nix-progress.sh — run a nix build and give it one trill card that fills up.
#
# The reference driver for `trill send --progress`: it reads nix's own
# `internal-json` log stream, counts what nix says it has left to do, and
# ticks a single keyed card from 0 to done. One card for the whole build,
# because a keyed progress send *replaces* its card instead of stacking a
# second one.
#
#   scripts/nix-progress.sh -- nix build .#trill-skill
#   scripts/nix-progress.sh --title "haus rebuild" -- haus rebuild build
#   scripts/nix-progress.sh --key ci --source ci -- nix flake check
#
# `--log-format internal-json` is appended for you when the command is a nix
# one and doesn't already say otherwise. Anything else runs untouched: with no
# `@nix` lines to read there is no bar, and you get the plain start/end cards.
#
# nix's messages and errors still reach your terminal, and this script exits
# with the command's exit code — it is a wrapper, not a runner. Per-derivation
# build logs are hidden the way nix's own bar hides them; TRILL_PROGRESS_VERBOSE=1
# brings them back (`nix build -L`).
#
# WIRING THIS TO YOUR REBUILD is haus's job, not trill's: trill owns the card,
# the layer owns which commands draw one. This script is the thing that layer
# would call, and the feel-test for the bar until it does.

set -uo pipefail

KEY=""
TITLE=""
SOURCE="nix"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key) KEY="${2:-}"; shift 2 ;;
    --title) TITLE="${2:-}"; shift 2 ;;
    --source) SOURCE="${2:-}"; shift 2 ;;
    --) shift; break ;;
    -h|--help) sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "nix-progress: unknown flag '$1' (see --help)" >&2; exit 64 ;;
  esac
done

if [[ $# -eq 0 ]]; then
  echo "nix-progress: nothing to run — put the command after --" >&2
  exit 64
fi

# The CLI is the app binary. On PATH when haus installed trill; the dev
# install is the fallback so a feel-test works out of a checkout.
TRILL="${TRILL_BIN:-$(command -v trill || true)}"
if [[ -z "$TRILL" ]]; then
  TRILL="$HOME/Applications/Trill.app/Contents/MacOS/Trill"
fi
if [[ ! -x "$TRILL" ]]; then
  echo "nix-progress: no trill binary (set TRILL_BIN=)" >&2
  exit 69
fi

TITLE="${TITLE:-$*}"
# One key per invocation by default, so two builds at once own two cards
# rather than fighting over one. Pass --key to make a rebuild replace the
# card yesterday's left behind.
KEY="${KEY:-nix-$$}"

# Nix only takes this as a flag, never as config, so the wrapper adds it.
CMD=("$@")
if [[ "${CMD[0]}" == *nix* && ! " ${CMD[*]} " == *" --log-format "* ]]; then
  CMD+=(--log-format internal-json)
fi

export TRILL_PROGRESS_KEY="$KEY" TRILL_PROGRESS_TITLE="$TITLE" \
       TRILL_PROGRESS_SOURCE="$SOURCE" TRILL_BIN_RESOLVED="$TRILL"

# nix writes its structured log to stderr and the build's own output to
# stdout; 2>&1 through the reader keeps both on your terminal in order.
set -o pipefail
"${CMD[@]}" 2>&1 | python3 "$(dirname "${BASH_SOURCE[0]}")/nix-progress.py"
STATUS=${PIPESTATUS[0]}

if [[ $STATUS -eq 0 ]]; then
  "$TRILL" send --key "$KEY" --source "$SOURCE" --kind done --progress 1 \
    --title "$TITLE" --body "done" >/dev/null || true
else
  # No bar on the ending: a failure isn't 100% of anything. It still lands on
  # the same card, because the card it replaces has a bar.
  "$TRILL" send --key "$KEY" --source "$SOURCE" --kind fault --urgency critical \
    --title "$TITLE" --body "failed (exit $STATUS)" >/dev/null || true
fi

exit "$STATUS"
