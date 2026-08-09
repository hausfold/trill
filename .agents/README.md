# `.agents/` — the harness-neutral layer

Every coding agent invents its own dotfile. This directory is the answer to
that: **the content lives here (or in `AGENTS.md`), and each client's own
directory holds nothing but wiring** — a pointer, a symlink, or a hook
registration. Switch harness, keep the flows.

> **One body, many pointers.** A rule, a flow, or a script is written *once*. If
> a file under `.claude/`, `.codex/`, `.opencode/` or `.github/` carries a
> project rule rather than a reference to one, it's a bug — the next agent, on a
> different client, runs without it.

Corollary: never "fix" a stale pointer by copying the current text into it.

The family-wide rationale — the four kinds of agent config, how to add a new
harness — is written once, in the workshop:
[`hausfold/workshop` → `.agents/README.md`](https://github.com/hausfold/workshop/blob/main/.agents/README.md).
The table below is only what's wired in *this* repo-to-be.

| Path | Read by | What it actually is |
|---|---|---|
| `AGENTS.md` | Codex, OpenCode, Cursor, Zed, Amp, Copilot-in-editor, and anything else that speaks [agents.md](https://agents.md) | **The source of truth.** Every project rule, starting with the one that explains everything: the compositor never blocks on, or trusts, a provider. |
| `CLAUDE.md` | Claude Code (CLI, desktop, web) | `@AGENTS.md` import + a table of Claude-only wiring. Claude Code reads only `CLAUDE.md`, so the import is how it gets the real file. |
| `GEMINI.md` | Gemini CLI | Symlink → `AGENTS.md`. |
| `opencode.json` | OpenCode | Names `AGENTS.md` explicitly. Belt and braces — OpenCode finds it anyway. |
| `.agents/setup.sh` | all of them, via the hooks below | Installs Determinate Nix in a bare cloud container, persists `PATH` + `NIX_SSL_CERT_FILE`. No-ops on macOS and where Nix already exists. |
| `.claude/settings.json` | Claude Code | `SessionStart` → `.agents/setup.sh`. |
| `.codex/hooks.json` + `.codex/config.toml` | Codex CLI | `SessionStart` → `.agents/setup.sh`, plus the flag that enables hooks. |
| `.opencode/plugins/nix-bootstrap.js` | OpenCode | Plugin load *is* session start; runs the same script, swallowing every error. |
| `.github/copilot-instructions.md` | GitHub Copilot (github.com, and the editor as a second source) | A hand-kept summary of `AGENTS.md`, **a real file and never a symlink** — Copilot reads through the GitHub API, where a symlink is just a path string. `AGENTS.md` wins if they drift. |

No repo-local flows yet. When trill grows one it goes in
`.agents/skills/<name>/SKILL.md`, symlinked into `.claude/skills/<name>/` and
`.opencode/skills/`, never copied.

## Caveats

- **Trill ejected from the workshop incubator on 2026-08-09.** This layer was
  kept complete throughout the incubation precisely so the eject moved a
  finished repo rather than one that had to grow its instructions afterwards —
  the one piece deliberately deferred was `.github/copilot-instructions.md`
  (there was no `hausfold/trill` for Copilot to read it from, and a file at
  `incubator/trill/.github/` is not a path GitHub resolves), and it landed with
  the eject.
- **Trill is a macOS app; a Linux cloud container can't build or feel-test it.**
  `xcodebuild` is macOS-only and banners need a real session. The bootstrap is
  there so a cloud session can resolve and re-lock the flake.
- **Feel-testing uses `scripts/dev-install.sh`, not a bare `xcodebuild`** — see
  `AGENTS.md`. An ad-hoc-signed build loses its TCC grant on every rebuild.
- **Codex repo-local hooks** have historically not fired in every interactive
  session ([openai/codex#17532](https://github.com/openai/codex/issues/17532)),
  and some builds want an absolute path for `hooks`. If `/hooks` doesn't list
  ours, point your own `~/.codex/config.toml` at this repo's `.codex/hooks.json`.
- **Whatever the harness, the fallback is the same:** `./.agents/setup.sh` is
  idempotent and safe to run by hand.
