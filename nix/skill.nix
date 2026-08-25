# trill's agent skill, as a derivation.
#
# The source is `ai/SKILL.md` at the repo root — one file, committed, the same
# one that gets embedded in the binary when `trill skill` lands. This derivation
# is how a *consumer* WILL get it. ⚠️ Nothing consumes it today, but the reason
# changed on 2026-08-25: haus DOES take trill as a flake input now, so
# `pkgs.trill-skill` is reachable — it is haus's `modules/ai/tool-skills.nix`
# that still lists only holt. Adding it there is its own change, for two reasons
# worth doing on purpose: that list is unconditional, while a skill for an app
# the machine doesn't have is worse than none; and this flake outputs darwin
# systems only, so the derivation that proves a listed skill name is real can't
# be evaluated by haus's Linux CI unguarded. Don't "fix" any of it by adding
# trill to bench's FAMILY — that advice survived route B unchanged. A standalone
# user will get the identical bytes from `trill skill install` — step 4 of the
# standard's rollout, not a verb that exists today.
#
# `$out/<tool>/SKILL.md` is the family standard's §6 layout (the workshop's
# notes/agent-surface.md): one nesting level, named for the skill, so a
# consumer links a directory that is already called the right thing and the
# TOOL decides its skill's folder name rather than whoever installs it. haus's
# own skill is flat, `$out/SKILL.md` — it predates the standard, and is the one
# exception rather than the pattern. Skill names are globally unique across the
# family: they all land in one shared `~/.claude/skills/`.
{
  lib,
  runCommand,
}:

runCommand "trill-skill"
  {
    meta = {
      description = "Agent skill teaching a coding agent to send notifications with trill";
      license = lib.licenses.mit;
      platforms = lib.platforms.all;
    };
  }
  ''
    mkdir -p "$out/trill"
    cp ${../ai/SKILL.md} "$out/trill/SKILL.md"

    skill="$out/trill/SKILL.md"

    # The frontmatter, and ONLY the frontmatter. Every client routes on `name`
    # and `description`, so a header that is missing, never closed, or whose
    # keys only appear down in the body produces a skill that installs, lists,
    # and never loads — indistinguishable, from the user's side, from the agent
    # not knowing trill exists. That is the failure worth failing a build over.
    head -1 "$skill" | grep -qx -- '---' \
      || { echo "ai/SKILL.md does not open with YAML frontmatter" >&2; exit 1; }
    front="$(tail -n +2 "$skill" | sed -n '1,/^---$/p')"
    printf '%s\n' "$front" | grep -qx -- '---' \
      || { echo "ai/SKILL.md's frontmatter block is never closed" >&2; exit 1; }

    printf '%s\n' "$front" | grep -q '^name: trill$' \
      || { echo "ai/SKILL.md's frontmatter has no 'name: trill' line" >&2; exit 1; }
    # One PHYSICAL line, by design: these guards are grep, and a description
    # written as a YAML folded scalar (`>-` plus an indented body) is valid YAML
    # that would silently stop being checked. The standard says one line.
    printf '%s\n' "$front" | grep -qE '^description: .{80,}' \
      || { echo "ai/SKILL.md's description is missing, too short to route on, or wrapped onto a second line" >&2; exit 1; }

    # A routing document that grew into a manual stops being read as one.
    lines=$(wc -l < "$skill")
    [ "$lines" -le 150 ] \
      || { echo "ai/SKILL.md is $lines lines; the standard caps a routing document at 150" >&2; exit 1; }
  ''
