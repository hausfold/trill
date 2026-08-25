#!/usr/bin/env bash
#
# dev-install.sh — build Trill from this checkout, sign it with a *stable*
# identity, and leave exactly one copy where macOS will find it.
#
# WHY THIS EXISTS (the Full Disk Access bug it fixes permanently)
#
# `xcodebuild … CODE_SIGNING_ALLOWED=NO` — the command CI runs, fine
# for tests — produces an **ad-hoc signed** bundle. macOS stores a TCC grant
# (Full Disk Access) against the app's *designated requirement*, and for an
# ad-hoc bundle that requirement pins the binary's **cdhash**, which changes on
# every single build. The moment a differently-hashed `com.hausfold.trill`
# launches, macOS can no longer match the app it granted, so it revokes: the
# switch in System Settings turns itself back off while you watch.
#
# Signing with the Developer ID makes that requirement name the **team**
# (88M28542LQ) instead of a hash — so the grant survives every rebuild, and
# you grant Full Disk Access once, ever.
#
# THE OTHER HALF, FOUND 2026-08-04: that only holds while nothing else claims
# the same bundle id. TCC keys Full Disk Access by **bundle id**, one row, and
# rewrites that row's stored requirement to whichever binary asked last. The
# Debug build — Apple-Development-signed under automatic signing — used to
# carry `com.hausfold.trill` too, so every `xcodebuild test` launched a host
# app that asked for FDA, failed to match, and took the row over:
#
#   Failed to match existing code requirement for subject com.hausfold.trill
#     stored:    … certificate leaf[subject.OU] = "88M28542LQ"        (installed)
#     presented: … "Apple Development: … (6NGM8QR7J9)"                (test host)
#   Service kTCCServiceSystemPolicyAllFiles does not allow prompting; recording denied.
#
# The next launch of the installed app then failed to match *that*, and was
# denied silently — this service never prompts. The fix is in the project, not
# here: Debug builds are `com.hausfold.trill.debug` (`PRODUCT_BUNDLE_IDENTIFIER`
# per configuration), so they can never touch the release row. If a grant does
# go missing, remove trill from Privacy & Security ▸ Full Disk Access and
# re-add this app, or `sudo tccutil reset SystemPolicyAllFiles com.hausfold.trill`.
#
# The other half of the same bug: several stale `Trill.app` copies
# (DerivedData, `build/`, old installs) all claim `com.hausfold.trill`, and
# Apple's own "Quit & Reopen" button relaunches **by bundle id** — so it can
# relaunch a copy the grant was never made against. This script unregisters
# the strays and leaves one canonical install at ~/Applications/Trill.app.
#
# Usage:
#   scripts/dev-install.sh                  build, sign, install, relaunch
#   scripts/dev-install.sh --reset-permissions
#                                           …and wipe trill's existing TCC
#                                           rows first (needed once, when
#                                           switching from an ad-hoc build:
#                                           the stale row can't be matched
#                                           against the new signature)
#
# Override the identity with TRILL_SIGN_IDENTITY= if you sign under another
# team.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="com.hausfold.trill"
INSTALL_PATH="$HOME/Applications/Trill.app"
DERIVED="$REPO_ROOT/build/dev-install"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

RESET_PERMISSIONS=0
[[ "${1:-}" == "--reset-permissions" ]] && RESET_PERMISSIONS=1

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. resolve a stable signing identity ------------------------------------

IDENTITY="${TRILL_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi
[[ -n "$IDENTITY" ]] || die "no 'Developer ID Application' identity in the keychain.
An ad-hoc build cannot hold a Full Disk Access grant across rebuilds — that is
the bug this script exists to fix. Install the Developer ID cert, or set
TRILL_SIGN_IDENTITY to another identity with a Team ID."

TEAM_ID="$(printf '%s' "$IDENTITY" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')"
say "signing as: $IDENTITY"

# --- 2. build ----------------------------------------------------------------

say "building Release…"

# ENABLE_CODE_COVERAGE=NO is not belt-and-braces, it is the fix for a bug that
# ate agent worktrees for weeks. This project ships no *shared* scheme, so
# `-scheme Trill` resolves the per-user autocreated one, whose coverage default
# is YES — and that leaks into a plain `build`, not just `test`:
# CLANG_COVERAGE_MAPPING comes out YES and the Release binary ships
# __llvm_prf_cnts. The app binary IS the trill CLI, `holt notify` execs it from
# every agent-pane hook, and the LLVM profile runtime writes `default.profraw`
# into whatever cwd it exits in — i.e. one untracked file per lane checkout,
# which `holt reap` then refuses to reap over. `ENABLE_CODE_COVERAGE = NO` in
# project.pbxproj is the real repair; this flag makes it explicit at the one
# call site that installs, and the guard below is what notices if either
# regresses. Coverage stays reachable on demand: `xcodebuild test
# -enableCodeCoverage YES` overrides both.
xcodebuild \
  -project "$REPO_ROOT/Trill.xcodeproj" \
  -scheme Trill \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_CODE_COVERAGE=NO \
  OTHER_CODE_SIGN_FLAGS='--timestamp' \
  build | tail -5

BUILT_APP="$DERIVED/Build/Products/Release/Trill.app"
[[ -d "$BUILT_APP" ]] || die "build produced no app at $BUILT_APP"

# --- 2b. refuse to install a profiling build ---------------------------------
#
# The failure this catches is silent by construction: an instrumented Trill
# behaves identically, and the only symptom is a `default.profraw` appearing in
# directories nobody built in. Check the Mach-O, not the settings — a section is
# the thing that actually decides.

# No pipe into `grep -q`: under `set -o pipefail` grep exits on its first match,
# otool takes a SIGPIPE, and the *pipeline* status is 141 — so a match would
# read as "no match" and the guard would wave through exactly what it exists to
# stop. And no `2>/dev/null` swallowing a missing binary into a clean pass: a
# guard that can't find its subject has failed, not passed.
BUILT_BIN="$BUILT_APP/Contents/MacOS/Trill"
[[ -f "$BUILT_BIN" ]] || die "no executable at $BUILT_BIN — the instrumentation guard has nothing to check, which is a failure, not a pass."
LOAD_COMMANDS="$(otool -l "$BUILT_BIN")" || die "otool could not read $BUILT_BIN"

if [[ "$LOAD_COMMANDS" == *__llvm_prf_cnts* ]]; then
  die "the build is coverage-instrumented (__llvm_prf_cnts in the binary).
Installing it would drop a default.profraw in the cwd of every process that
runs the CLI — including every agent worktree \`holt notify\` fires from, which
then can't be reaped. Check ENABLE_CODE_COVERAGE is still NO in
Trill.xcodeproj/project.pbxproj, and that nothing put it back via an xcconfig
or a shared scheme:
  xcodebuild -project Trill.xcodeproj -scheme Trill -configuration Release \\
    -showBuildSettings | grep -E 'ENABLE_CODE_COVERAGE|CLANG_COVERAGE_MAPPING'"
fi

# --- 3. evict every other copy that claims this bundle id --------------------
#
# Not cosmetic: whichever copy LaunchServices resolves is the one Apple's
# "Quit & Reopen" relaunches and the one System Settings' + button adds.
#
# `-u` alone does NOT hold. It evicts the *record*, not the bundle, and
# LaunchServices re-scans and re-adds any `Trill.app` still sitting on disk —
# so the strays come back on the next index pass and the app shows up three
# times in a launcher again. Step 4b is the half that makes this stick.

say "unregistering stale $BUNDLE_ID bundles…"
"$LSREGISTER" -dump 2>/dev/null \
  | sed -n 's/^[[:space:]]*path:[[:space:]]*\(.*Trill\.app\)[[:space:]]*(.*/\1/p' \
  | sort -u \
  | while read -r stale; do
      [[ "$stale" == "$INSTALL_PATH" ]] && continue
      printf '    - %s\n' "$stale"
      "$LSREGISTER" -u "$stale" 2>/dev/null || true
    done

# --- 4. install the one canonical copy ---------------------------------------

say "installing → $INSTALL_PATH"
/usr/bin/pkill -x Trill 2>/dev/null || true
rm -rf "$INSTALL_PATH"
mkdir -p "$(dirname "$INSTALL_PATH")"
/usr/bin/ditto "$BUILT_APP" "$INSTALL_PATH"

# Re-sign in place: `ditto` preserves the signature, but signing the installed
# path is what makes `codesign --verify` and TCC agree on this exact bundle.
codesign --force --options runtime --timestamp \
  --entitlements "$REPO_ROOT/Trill/Config/Trill.entitlements" \
  --sign "$IDENTITY" "$INSTALL_PATH"
codesign --verify --strict --verbose=1 "$INSTALL_PATH"

ACTUAL_TEAM="$(codesign -dvvv "$INSTALL_PATH" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$ACTUAL_TEAM" != "not set" && -n "$ACTUAL_TEAM" ]] \
  || die "installed bundle still has no Team ID — the grant would not survive a rebuild"
say "team identifier: $ACTUAL_TEAM (grants now survive rebuilds)"

"$LSREGISTER" -f "$INSTALL_PATH"

# --- 4b. delete the build output, so it cannot re-register -------------------
#
# The installed copy is the only one anyone should ever resolve, and by this
# line it exists, is signed, and is registered. Everything under `build/` is
# now redundant — including the DerivedData tree this very script just built,
# which is otherwise a stray it re-creates on every single run.
#
# Scoped to `$REPO_ROOT/build` and guarded on the path being non-empty: this
# is an `rm -rf` in a script people run often, and the failure mode of a
# mis-set REPO_ROOT is not one worth risking for a tidier line.

if [[ -n "$REPO_ROOT" && -d "$REPO_ROOT/build" ]]; then
  say "removing build output under $REPO_ROOT/build (would re-register otherwise)"
  while IFS= read -r stray; do
    [[ "$stray" == "$INSTALL_PATH" ]] && continue
    printf '    - %s\n' "$stray"
    "$LSREGISTER" -u "$stray" 2>/dev/null || true
  done < <(find "$REPO_ROOT/build" -maxdepth 6 -name "Trill.app" -type d 2>/dev/null)
  rm -rf "${REPO_ROOT:?}/build"
fi

# --- 4c. put `trill` on PATH -------------------------------------------------
#
# The app binary IS the CLI, and until this line nothing ever gave it a name a
# shell could find: every install source dropped a bundle and stopped there, so
# `trill send` failed on a Mac with trill running in the menu bar. Callers
# papered over it by hunting for the bundle themselves (`holt notify` still
# carries that fallback list), which is fine for one Go program and hopeless as
# an instruction to anybody else.
#
# A symlink, not a copy: the executable is signed and notarized as part of the
# bundle, and a copy outside it is nested code torn out of that seal.
#
# NOT /usr/local/bin: this script must never need sudo. And not a fixed
# ~/.local/bin either — that is the conventional answer and it is on nobody's
# PATH by default on macOS, so hardcoding it writes a file that exists and a
# command that never runs. Pick a directory of the user's that their LOGIN
# shell already names, and only fall back to ~/.local/bin when there is none —
# saying so, rather than reporting a link as an install.
#
# Nix-managed bins are excluded even when they are on PATH: a link written into
# /etc/profiles/per-user/… or the store is gone at the next rebuild.
#
# The same rule, in Swift, is SystemIntegration.cliLinkDirectory — the app
# repeats this at launch for the install sources that run no script at all (a
# release ZIP dragged to /Applications, a future cask). The Nix path comes
# through neither: `pkgs.trill` ships its own bin/trill (nix/package.nix) and
# haus's room links the copy it places.

CLI_TARGET="$INSTALL_PATH/Contents/MacOS/Trill"

# Ask the LOGIN shell, not this one: this script may itself have been run from
# somewhere with a fuller PATH, and the profile is where PATH is assembled.
LOGIN_PATH="$("${SHELL:-/bin/zsh}" -l -c 'echo $PATH' 2>/dev/null || true)"

CLI_DIR=""
for candidate in "$HOME/.local/bin" "$HOME/bin"; do
  case ":$LOGIN_PATH:" in *":$candidate:"*) CLI_DIR="$candidate"; break ;; esac
done
if [[ -z "$CLI_DIR" ]]; then
  # First home-owned, non-nix entry on the real PATH, whatever it is called.
  while IFS= read -r entry; do
    [[ "$entry" == "$HOME/"* ]] || continue
    case "$entry" in /nix/store/*|/etc/profiles/*|/run/current-system/*) continue ;; esac
    CLI_DIR="$entry"; break
  done < <(printf '%s' "$LOGIN_PATH" | tr ':' '\n')
fi
ON_PATH=1
if [[ -z "$CLI_DIR" ]]; then
  CLI_DIR="$HOME/.local/bin"
  ON_PATH=0
fi
CLI_LINK="$CLI_DIR/trill"

if [[ -e "$CLI_LINK" && ! -L "$CLI_LINK" ]]; then
  say "leaving $CLI_LINK alone — it is a real file, not our symlink"
else
  mkdir -p "$CLI_DIR"
  ln -sfn "$CLI_TARGET" "$CLI_LINK"
  say "linked $CLI_LINK → $CLI_TARGET"
fi

RESOLVED=""
if (( ON_PATH )); then
  RESOLVED="$("${SHELL:-/bin/zsh}" -l -c 'command -v trill' 2>/dev/null || true)"
else
  printf '\033[1;33mnote:\033[0m %s\n' "$CLI_DIR is not on your login shell's PATH, so \`trill\` still won't resolve.
      Add it:  export PATH=\"$CLI_DIR:\$PATH\""
fi

# --- 5. optional: clear the un-matchable TCC rows ----------------------------

if (( RESET_PERMISSIONS )); then
  say "resetting trill's TCC rows (you will re-grant Full Disk Access once)"
  sudo tccutil reset SystemPolicyAllFiles "$BUNDLE_ID" || true
  tccutil reset All "$BUNDLE_ID" 2>/dev/null || true
fi

# --- 6. launch ---------------------------------------------------------------

say "launching"
open "$INSTALL_PATH"

cat <<EOF

Installed: $INSTALL_PATH  (Team $ACTUAL_TEAM)
CLI:       $CLI_LINK${RESOLVED:+  (resolves: $RESOLVED)}

Full Disk Access, once:
  Trill menu bar → Settings… → Unlock System Mirror…
  The assistant walks you through the pane and closes itself the moment the
  grant lands — access is picked up live, so either answer to Apple's
  "Quit & Reopen" sheet works. "Later" changes nothing; "Quit & Reopen"
  is finished by Trill's own watchdog, since macOS quits background-only
  apps without ever performing the reopen.

Every later run of this script keeps that grant.
EOF
