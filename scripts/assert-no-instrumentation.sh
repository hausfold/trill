#!/usr/bin/env bash
#
# assert-no-instrumentation.sh — fail if any Mach-O under the given paths was
# built with profiling instrumentation.
#
# WHY THIS EXISTS
#
# `ENABLE_CODE_COVERAGE = NO` is pinned in both project-level configurations
# (see AGENTS.md) because Xcode's default is YES, this repo ships no *shared*
# scheme, and the Xcode 26 build service applies the autocreated scheme's
# coverage default to a plain `build`, not just to `test`. An instrumented
# binary is *behaviourally identical* — it runs, it passes tests, it notarizes —
# and the only symptom is that LLVM's profile runtime writes a
# `default.profraw` into whatever directory the process exits in.
#
# For trill that is worse than for most: the app binary IS the `trill` CLI, and
# `holt notify` execs it from every agent-pane hook. So one release would drop
# an untracked file into every agent worktree on the machine, and `holt reap`
# refuses to reap a checkout with uncommitted work in it — lanes pile up until
# someone deletes files by hand. That is hausfold/trill#14, and it shipped once.
#
# A setting nothing checks is a setting that comes back. perch carries the
# identical guard for the identical reason; keep them in step.
#
# Usage:
#   scripts/assert-no-instrumentation.sh <path>…      an .app bundle, or a binary
#
# Exits 0 only if it examined at least one Mach-O and none carried the section.

set -euo pipefail

MARKER=__llvm_prf_cnts
examined=0
dirty=()

for target in "$@"; do
  if [[ ! -e "$target" ]]; then
    printf 'error: %s does not exist — the guard had nothing to check, which is a failure, not a pass.\n' "$target" >&2
    exit 1
  fi

  # No -perm filter on the find below: git preserves only the exec bit, so a
  # committed or vendored .dylib/.framework arrives 0644 and an executable-only
  # sweep would walk straight past it — a guard that can silently pass is the
  # failure mode this script exists to end. -H so a symlinked bundle path (nix
  # installs Trill.app as a store symlink) is followed rather than skipped.
  while IFS= read -r f; do
    # The LC_SEGMENT test is what separates Mach-O from everything else in a
    # bundle — nibs, Assets.car, plists, shell scripts. Don't be tempted to
    # lean on otool's exit status instead: it returns 0 on a plain text file
    # and simply prints nothing, so `|| continue` alone would filter nothing.
    load_commands="$(otool -l "$f" 2>/dev/null)" || continue
    [[ "$load_commands" == *LC_SEGMENT* ]] || continue
    examined=$((examined + 1))
    # No `| grep -q`: under `set -o pipefail`, grep exits at its first match,
    # otool takes a SIGPIPE, and the pipeline status is 141 — so a hit would
    # read as a miss and this guard would wave through exactly what it exists
    # to stop.
    if [[ "$load_commands" == *"$MARKER"* ]]; then
      dirty+=("$f")
    fi
  done < <(find -H "$target" -type f 2>/dev/null)
done

if (( examined == 0 )); then
  printf 'error: found no Mach-O binaries under: %s\n' "$*" >&2
  printf '       A guard with no subject has failed, not passed — check the path.\n' >&2
  exit 1
fi

if (( ${#dirty[@]} > 0 )); then
  printf 'error: %d binary(ies) carry %s — built with profiling instrumentation:\n' "${#dirty[@]}" "$MARKER" >&2
  printf '  %s\n' "${dirty[@]}" >&2
  cat >&2 <<'WHY'

Shipping these would drop a `default.profraw` into the working directory of
every process that runs them — and the trill binary is run by `holt notify`
from every agent pane, so that is one untracked file per agent worktree, after
which `holt reap` refuses to sweep the checkout.

Check that ENABLE_CODE_COVERAGE is still NO in both project-level build
configurations, and that nothing reintroduced it via an xcconfig or the
autocreated scheme in xcuserdata/:

  xcodebuild -project Trill.xcodeproj -scheme Trill -configuration Release \
    -showBuildSettings | grep ENABLE_CODE_COVERAGE
WHY
  exit 1
fi

printf 'clean: %d Mach-O binary(ies) examined, none instrumented\n' "$examined"
