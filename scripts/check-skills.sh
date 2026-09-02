#!/usr/bin/env bash
# The guards on trill's agent skills — one copy, run from three places.
#
# Every failure here is INVISIBLE at runtime. A skill whose frontmatter is
# missing, unterminated, or whose `name:` disagrees with the directory it
# installs into is installed fine, listed fine, and never loaded —
# indistinguishable, from the user's side, from the agent not knowing trill
# exists. So it has to be a build failure, and it has to fire in CI.
#
# Which is why this is a script and not a `runCommand` body: trill's CI builds
# an Xcode project with no Nix anywhere, so guards living only in nix/skill.nix
# would run on a developer's machine and nowhere else. `nix/skill.nix` calls
# this, `build.yml` calls it directly, and so can you.
#
# It DISCOVERS the skills rather than being handed a list. A hardcoded list here
# plus one in the generator plus a third in CI is three places to forget a new
# skill, and forgetting it in the CI copy reinstates exactly the gap this
# script exists to close.
#
# Usage: scripts/check-skills.sh <ai-dir> [<generated-swift> <generator>]
#
#   <ai-dir>/SKILL.md        → checked as `trill`   (the tool's own skill)
#   <ai-dir>/*/SKILL.md      → checked as its directory name
#
# With the last two arguments it also proves the EMBEDDED copy still matches the
# Markdown — the check that makes `trill skill` trustworthy. Without them it
# checks the prose alone, which is all nix/skill.nix ships.
set -euo pipefail

status=0
bad() { printf '%s\n' "$*" >&2; status=1; }

case "$#" in
1 | 3) : ;;
*)
  printf 'usage: check-skills.sh <ai-dir> [<generated-swift> <generator>]\n' >&2
  exit 2
  ;;
esac
root="$1"
[ -d "$root" ] || { printf 'check-skills.sh: no such directory: %s\n' "$root" >&2; exit 2; }
# At least the tool's own has to be there — an empty run must not pass.
[ -f "$root/SKILL.md" ] || { printf 'check-skills.sh: no %s/SKILL.md\n' "$root" >&2; exit 2; }

# name<TAB>path, the tool's own first.
skills="$(printf '%s\t%s\n' trill "$root/SKILL.md")"
for dir in "$root"/*/; do
  [ -f "$dir/SKILL.md" ] || continue
  skills="$skills
$(printf '%s\t%s' "$(basename "$dir")" "$dir/SKILL.md")"
done

while IFS="$(printf '\t')" read -r name skill; do
  [ -n "$name" ] || continue
  [ -f "$skill" ] || { bad "$name: no SKILL.md at $skill"; continue; }

  # The frontmatter, and ONLY the frontmatter. Every client routes on `name`
  # and `description`; the same keys further down the body are prose.
  if ! head -1 "$skill" | grep -qx -- '---'; then
    bad "$name: SKILL.md does not open with YAML frontmatter"
    continue
  fi
  front="$(tail -n +2 "$skill" | sed -n '1,/^---$/p')"
  printf '%s\n' "$front" | grep -qx -- '---' \
    || { bad "$name: SKILL.md frontmatter block is never closed"; continue; }

  # The directory name and the `name:` key are two identifiers for one skill —
  # the path a client scans, and the string it routes on. A mismatch installs a
  # skill under a name nothing ever asks for.
  printf '%s\n' "$front" | grep -qx "name: $name" \
    || bad "$name: SKILL.md has no 'name: $name' line"

  # One PHYSICAL line, by design: these guards are grep, and a description
  # written as a YAML folded scalar (`>-` plus an indented body) is valid YAML
  # that would silently stop being checked. The family standard says one line.
  printf '%s\n' "$front" | grep -qE '^description: .{80,}' \
    || bad "$name: SKILL.md description is missing, too short to route on, or wrapped onto a second line"

  # A routing document that grew into a manual stops being read as one.
  lines=$(wc -l <"$skill")
  [ "$lines" -le 150 ] \
    || bad "$name: SKILL.md is $lines lines; the standard caps a skill at 150"

  # `trill skill install` writes the embedded body plus one newline, so a file
  # that doesn't end in one would install as a file that differs from itself
  # and be "left alone" forever after.
  if [ -n "$(tail -c 1 "$skill")" ]; then
    bad "$name: SKILL.md does not end with a newline"
  fi
# A pipe would put this loop in a subshell and throw `status` away with it, so
# every failure would print and the script would still exit 0.
done <<EOF
$skills
EOF

# The embedded copy. Regenerating into a temp file and diffing is the whole
# check: it needs no parser, and it catches the one failure that matters —
# somebody edited the Markdown and shipped a binary still printing the old
# prose, which is a confidently-wrong instruction with a nice format.
if [ "$#" -eq 3 ]; then
  generated="$2" generator="$3"
  if [ ! -f "$generated" ]; then
    bad "trill: no generated skills at $generated — run $generator"
  elif [ ! -x "$generator" ]; then
    bad "trill: $generator is not executable"
  else
    tmp="$(mktemp "${TMPDIR:-/tmp}/trill-skills.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    "$generator" "$tmp" "$root" >/dev/null
    diff -u "$generated" "$tmp" \
      || bad "trill: $generated is stale — run $generator and commit the result"
  fi
fi

exit "$status"
