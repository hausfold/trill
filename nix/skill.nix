# trill's agent skill, as a derivation.
#
# The source is `ai/SKILL.md` at the repo root — one file, committed, and the
# same one `scripts/generate-skills.sh` bakes into the binary that answers
# `trill skill`. This derivation is how a *consumer* gets it without installing
# trill at all. haus installs it: `modules/ai/tool-skills.nix`
# names `trill`, gated on `haus.notifications.compositor` (a skill for an app
# the machine doesn't have is worse than none), so the skill lands in every AI
# client on a Mac running trill and on no other. Two consequences for a rename:
# the name is a promise haus's `.#tool-skills` check proves at build time, so a
# rename here is a red rebuild there until haus's list moves with the lock bump
# — and that proof only runs on a Mac, because this flake outputs darwin systems
# only and haus's Linux CI drops the entry to null. Don't "fix" any of it by
# adding trill to bench's FAMILY.
#
# `trill skill install` exists now, and does NOT overlap this. It is the
# standalone user's door — a release ZIP dragged to /Applications, with no layer
# to install anything for them — and on a haus machine it finds the store
# symlinks this derivation put there and refuses, by name, rather than writing
# through them. Two audiences, one set of bytes.
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
  bash,
}:

runCommand "trill-skill"
  {
    nativeBuildInputs = [ bash ];
    meta = {
      description = "Agent skill teaching a coding agent to send notifications with trill";
      license = lib.licenses.mit;
      platforms = lib.platforms.all;
    };
  }
  ''
    # The whole ai/ tree, not one named file: the layout below is DERIVED from
    # it, so a second skill needs no edit here, in the generator, or in CI.
    ai=${../ai}

    mkdir -p "$out/trill"
    cp "$ai/SKILL.md" "$out/trill/SKILL.md"

    for dir in "$ai"/*/; do
      [ -f "$dir/SKILL.md" ] || continue
      name="$(basename "$dir")"
      mkdir -p "$out/$name"
      cp "$dir/SKILL.md" "$out/$name/SKILL.md"
    done

    # The guards live in scripts/check-skills.sh, not here, and that is the
    # point: trill's CI builds an Xcode project with no Nix anywhere, so a guard
    # written into this derivation would run on a developer's machine and
    # nowhere else. Every failure it catches — missing frontmatter, a `name:`
    # that disagrees with the directory, a description folded onto a second
    # line — is invisible at runtime: the skill installs, lists, and is never
    # loaded.
    #
    # One argument, not three: the *embed* check (does the Swift still match
    # the Markdown?) belongs to the build that compiles Swift, and `build.yml`
    # runs it there. Asking for it here would make haus's `.#tool-skills` check
    # fail over a file it has no way to see.
    bash ${../scripts/check-skills.sh} "$ai"
  ''
