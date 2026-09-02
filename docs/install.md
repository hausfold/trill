# Installing trill

macOS 14 or newer. One app bundle, about a megabyte, no runtime and no account.

## the release

[Download the latest ZIP](https://github.com/hausfold/trill/releases/latest),
unzip, drag `Trill.app` to `/Applications`, launch it once. It's
Developer-ID signed and notarized by Apple, so Gatekeeper opens it without a
right-click dance. There's no Dock icon: a small dotted circle in the menu bar —
Inbox, Settings, Report a Bug, Quit — is the whole chrome, and the banners are
the app.

Then, if you use a coding agent, `trill skill install` — it writes trill's
[agent skill](../ai/SKILL.md) into every client it finds (Claude Code, Codex,
OpenCode, pi), so *"tell me when this build finishes"* works first try. It never
overwrites: anything already there and different is named and left alone. On a
haus machine you can skip it — the layer installed the same file already, and
the command will tell you so rather than fighting it for the path.

## Nix

```nix
inputs.trill.url = "github:hausfold/trill";
```

The flake's `overlays.default` puts `trill` in `pkgs` (the same notarized ZIP,
unpacked verbatim — a from-source Nix build of an Xcode project isn't possible
on macOS 26), plus `trill-skill` if you want the
[agent surface](../ai/SKILL.md) without the app.

On [haus](https://github.com/hausfold/haus) it's one line —
`haus.notifications.compositor = true;` — which copies the bundle to a fixed
`/Applications/Trill.app` (TCC grants are keyed per app path, so a store path
would drop Full Disk Access on the rebuild that installed the fix) and installs
the agent skill into every AI client on the machine.

Building and feel-testing from a checkout is `AGENTS.md` ▸ Verifying, which is
where that decision is stated once.

## what puts `trill` on your PATH

The app **is** the CLI — one signed binary serves both the daemon and every
verb — so all it takes is a symlink under a name a shell can find. Whoever
installs the bundle places it:

| install | who puts `trill` on PATH |
|---|---|
| Nix (`pkgs.trill`) | the package's own `bin/trill` |
| `scripts/dev-install.sh` | a link in a directory of yours already on PATH |
| the release ZIP, dragged to /Applications | **the app itself**, at first launch |

The last two pick the directory from your login shell's own `PATH` rather than
assuming one: `~/.local/bin` is the conventional answer and is on nobody's PATH
by default on macOS, so hardcoding it writes a file that exists and a command
that never runs. Nix-managed bins are skipped even when they *are* on PATH — a
link written there is gone at the next rebuild.

The app's own turn is deliberately timid. It places the link only when nothing
else already answers `trill`, never replaces a real file sitting on the name,
and never claims the name from a Debug build. Turn it off with `"cliLink":
false` in `~/.config/trill/config.json`, or in **Settings ▸ General** — which
also tells you what `trill` resolves to right now, and says so plainly when the
link is placed but its directory is on no PATH.

**`trill: command not found` is not "trill isn't installed."** The app is always
its own CLI: `/Applications/Trill.app/Contents/MacOS/Trill` takes every verb.

(A desktop that copies the bundle to a fixed path adds no fourth row. haus's
`haus.notifications.compositor` room puts nothing on PATH itself — grants are
keyed per app path, and its own `trill` wrapper resolves that path at call time,
which is the right shape when whether the bundle exists is a runtime fact.)
