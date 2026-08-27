# CLAUDE.md

@AGENTS.md

<!--
Everything above this line is imported from AGENTS.md — the one set of project
instructions, shared by every harness. Put project rules THERE, not here, or
Codex/OpenCode/Copilot silently run without them.

Only Claude-specific wiring belongs below.
-->

## Claude-specific wiring (nothing project-level here)

| Thing | Where | Notes |
|---|---|---|
| Project instructions | `AGENTS.md`, imported above | Claude Code reads only `CLAUDE.md`, so this file exists purely to import it. |
| Session bootstrap | `.claude/settings.json` → `SessionStart` → `.agents/setup.sh` | Same script Codex and OpenCode call. Installs Nix in cloud containers, no-ops locally. |
| Worktree hooks | `~/.claude/settings.json` (yours, not the repo's) → `scruff hook create` / `scruff hook remove` | Declared by haus and re-asserted every rebuild, so they self-heal when Claude rewrites that file. No repo in the family hand-edits it. |

The full cross-harness map is [`.agents/README.md`](./.agents/README.md).
