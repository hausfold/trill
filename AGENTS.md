# AGENTS.md

**Trill** — a quiet, scriptable notification compositor for macOS. Draws its
own silent banners for events from local sources (CLI socket today; an
experimental read-only mirror of Apple's `usernoted` store behind a flag).
Part of the [hausfold](https://github.com/hausfold) family; stands alone
like pounce and perch.

**This file is the one set of instructions, for every agent** — Claude Code,
Codex, OpenCode, Cursor, Copilot alike, directly or through a one-line pointer.
Per-client wiring lives in that client's own file; the content stays here or in
[`.agents/`](./.agents/README.md).

## Am I in the right repo? (routing)

**This repo owns THE NOTIFICATION COMPOSITOR** — the daemon, its providers,
the rules engine, the banner/inbox UI, and the `trill` CLI. Nothing about how
it's launched, themed at the source, or packaged.

| Want to change… | Repo |
|---|---|
| the trill app (compositor, providers, rules, CLI, inbox) | **you are here** |
| how trill is *installed* on the system (flake wiring, launchd) | `haus` (the layer) |
| the palette trill is themed with (source hex) | `nebelung` |
| DND / Focus toggling ("Hush") | `haus` (the layer) — trill only deep-links there |
| trill's Homebrew cask (once released) | `homebrew-tap` — CI-owned. The `trill` cask token is free |
| the flake's release pin (`nix/release.nix`) | this repo — **CI-owned**; never hand-bump |

> **Whatever agent you are, enforce this.** A color hex, a launchd plist, or a
> Focus toggle does not belong here even if it would work.

## The one rule that explains everything

**The compositor never blocks on — or trusts — a provider.** Every provider
is supervised in its own task, speaks only `NotificationEvent` (its native
types stop at its own boundary), advertises `ProviderHealth` from an explicit
`probe()`, and when it fails it fails *closed into "off with a reason"*,
never into a broken pipeline. Corollaries:

- **System Mirror is quarantined.** The `usernoted` store is opened
  `SQLITE_OPEN_READONLY`, schema-probed before every session, and disabled
  with a visible reason on any drift. It is opt-in, experimental, and the
  app must stay fully useful without it. No usernoted type or column name
  may appear outside `Providers/SystemMirror/`.
- **trill reads Apple's settings; it never writes them.** `trill doctor` and
  the "Silence Native Banners" helper decode the private per-app store
  read-only (`Platform/NotificationSettingsAudit`)
  to say which apps macOS still banners or sounds itself. Opening the pane
  and animating the two clicks is the whole offer — do **not** add a "fix it
  for me" that writes that plist, however easy it looks. Only the three
  corroborated bits are read (on-screen alert `1<<3`/`1<<4`, sound `1<<2`, and
  **allow-notifications `1<<25`**); don't extend to bits whose meaning is
  folklore, and if you must, corroborate against real data first and say so in
  the comment. **Never read style or sound without checking `1<<25` first** —
  macOS freezes those bits at their last values when the master switch goes
  off, so skipping it reports every app the user already silenced. That bug
  shipped once. Bit 29 is the counter-example worth remembering: it looked
  like the allow bit until its set turned out to be the community's
  "time-sensitive apps" list. And when you touch the helper's demo, **check
  the pane on the current macOS first** — Tahoe replaced None/Banners/Alerts
  with a Desktop checkbox plus Temporary/Persistent, and the demo shipped once
  miming controls that no longer existed. The bits didn't move; the words did,
  and the words are the whole product here.
- **Read the store macOS actually writes, and admit when you can't.** On
  macOS 26 the per-app switches live in
  `~/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist`.
  **`com.apple.ncprefs` is a stale mirror** — same `apps` array, same
  plausible `flags`, not what System Settings writes. Measured here:
  byte-identical to a 17-day-old copy across a change made in the pane and 45
  minutes of watching, while the group container took that change within
  seconds. Every write-up online names ncprefs, which is exactly why it's a
  trap; trill shipped it once and the helper panel looked broken as a result.
  That container is TCC-protected, so the read needs **Full Disk Access** — and
  therefore the audit has **three** verdicts, not two: noisy, quiet, and *can't
  tell*. `readAll()` returns nil for the third; rendering it as "all quiet" is
  the bug that must never come back (`trill doctor` exits **5**, Settings says
  "can't tell", the helper still walks but confirms nothing).
- **The helper advances on the user's word, not on a watch.** Because that
  store needs FDA and can't be assumed readable, the walkthrough's **Done**
  button is the mechanism and the poll is a bonus that ticks apps off where
  it can. Don't "fix" the panel by making it wait for confirmation again.
- **The queue is the truth; panels are disposable.** Display topology
  rebuilds re-render from `BannerQueue` state. Never park event state in a
  panel or view.
- **No sound.** There is no audio call anywhere in this codebase; don't add
  one, even "just for critical".
- **No notification content in logs.** Ids and source slugs only —
  `Logger` privacy annotations are load-bearing.
- **Never steal focus.** Banners ride non-activating panels; nothing in
  this app may take key focus except windows the user summoned (inbox,
  settings).
- Decisions are pure: `PolicyEngine` reads (event, rules, clock) and touches
  no I/O. New delivery behaviors go through `DeliveryDecision`, not ad-hoc
  branches in the queue.

## Layout (pounce/perch convention)

```text
Trill/
  App/           entry, composition root, settings
  CLI/           `trill send/ping` — same binary, CLI personality
  Domain/        NotificationEvent, RuleSet, PolicyEngine (pure)
  Providers/     protocol + Socket (shipping) + SystemMirror (quarantined)
  Repositories/  EventRepository actor: supervise, normalize, dedupe, fan out
  Persistence/   AppDatabase — trill's OWN sqlite; the only writer in the app
  Compositor/    ScreenGeometry (pure), BannerQueue, panels, window system
  Platform/      ActionRouter, SystemIntegration (all Apple hooks, one file)
  UI/            BannerView, InboxView, SettingsView
TrillTests/      geometry, policy, pipeline — pure logic tests, no display
```

## The agent surface (`ai/SKILL.md`)

**Don't confuse it with this file.** `AGENTS.md` is for an agent working **on**
trill, from a checkout. [`ai/SKILL.md`](./ai/SKILL.md) is for an agent **using**
it — on a stranger's Mac, with no checkout, when their human says *"tell me when
this finishes"*. It is the routing document that makes that sentence work first
try: the verbs, the six exit codes, the rules file, and when the answer is
something else entirely.

It is bound by the family standard, [the workshop's
`notes/agent-surface.md`](https://github.com/hausfold/workshop/blob/main/notes/agent-surface.md) —
≤150 lines, no flag dumps (that's `trill help`), and the `description`
frontmatter names **the phrases a user says**, not the features trill has. A
description written as a feature summary is true, well written, and never loads.

Two of this repo's invariants have to survive into that file or an agent will
promise what trill deliberately won't do: **there is no sound**, and **trill
reads Apple's notification settings but never writes them** — `doctor` names the
noisy apps and the clicking stays the user's. The third is exit **5**: *can't
tell* is a verdict, and an agent that renders it as "all quiet" reproduces the
bug that already shipped once.

`nix/skill.nix` ships it as `pkgs.trill-skill` (`$out/trill/SKILL.md`); the
build fails if the frontmatter is missing, because a skill without it is
installed, listed, and never loaded. ⚠️ **Nothing consumes that package yet** —
trill is not a haus flake input and carries no lock edge on purpose, so until
the planned leaf overlay lands, a user gets this skill from `trill skill
install` once that verb exists. **Don't add trill to `bench`'s `FAMILY` to fix
that.**

**Every claim in it must be runnable.** When you change a verb, a flag or an
exit code, change `ai/SKILL.md` in the same PR — a stale line there is a
confidently-wrong instruction with a nice format.

## Verifying

`xcodebuild -project Trill.xcodeproj -scheme Trill test` (or let CI run it).
Geometry, policy, queue, and wire-format logic are all testable headless —
keep it that way: anything that *can* be a pure function with a test should
be. Feel-testing banners needs a real session: build, run, `trill send`.

**Debug builds carry their own bundle id (`com.hausfold.trill.debug`) — leave
it that way.** TCC keys Full Disk Access by *bundle id*, one row per id, and
rewrites that row's stored code requirement to whichever binary asked last. If
Debug shared the release id, every `xcodebuild test` would launch an
Apple-Development-signed host, ask for FDA, fail to match, and take the row
over — after which the installed Developer-ID app is denied silently, because
`kTCCServiceSystemPolicyAllFiles` never prompts. It reads as a signing bug and
isn't. Debug also gets its own `Application Support/Trill (debug)` so a test run
can't bind the installed daemon's socket or write its database.

**Feel-test with `scripts/dev-install.sh`, not a bare `xcodebuild`.** A
`CODE_SIGNING_ALLOWED=NO` build is ad-hoc signed, and macOS pins a TCC grant
(Full Disk Access) to an ad-hoc bundle's **cdhash** — so the switch in System
Settings revokes itself on your next build, and stale `Trill.app` copies all
claiming `com.hausfold.trill` make Apple's "Quit & Reopen" relaunch the wrong
one. The script signs with the Developer ID (team-anchored requirement → the
grant survives every rebuild), unregisters the strays, and installs one copy at
`~/Applications/Trill.app`. Pass `--reset-permissions` once when coming from an
ad-hoc build.

Cloud sessions: edit + test-plan only; `xcodebuild` and feel-testing are
macOS-local jobs (see the workshop's `AGENTS.md`, "Cloud sessions"). The shared
`.agents/setup.sh` gets Nix onto a bare container so the flake resolves; it
cannot make a Linux box build a macOS app.
