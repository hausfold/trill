# trill's agent skill, as a derivation.
#
# The source is `ai/SKILL.md` at the repo root — one file, committed, the same
# one that gets embedded in the binary when `trill skill` lands. This derivation
# is how a *consumer* gets it. haus installs it: `modules/ai/tool-skills.nix`
# names `trill`, gated on `haus.notifications.compositor` (a skill for an app
# the machine doesn't have is worse than none), so the skill lands in every AI
# client on a Mac running trill and on no other. Two consequences for a rename:
# the name is a promise haus's `.#tool-skills` check proves at build time, so a
# rename here is a red rebuild there until haus's list moves with the lock bump
# — and that proof only runs on a Mac, because this flake outputs darwin systems
# only and haus's Linux CI drops the entry to null. Don't "fix" any of it by
# adding trill to bench's FAMILY. There is no `trill skill install` verb and no
# need for one.
#
# `$out/<tool>/SKILL.md` is the family standard's compliant-tool layout (the workshop's
# docs/agent-surface.md): one nesting level, named for the skill, so a
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
