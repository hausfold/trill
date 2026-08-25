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
| which calendars sync to this Mac at all | Apple's Calendar / Internet Accounts — trill only *reads* what EventKit already has |
| how trill is *installed* on the system (flake wiring, launchd) | `haus` (the layer) |
| whether `trill` resolves on PATH | **shared, by install source** — `nix/package.nix` ships `bin/trill`; `scripts/dev-install.sh` links into a directory on the real login PATH; the app itself covers an install that runs no script (`SystemIntegration.ensureCLILink`), and defers to anything already answering the name. Change the one that matches the source you're fixing, and keep the README's table honest. ⚠️ A desktop that copies the bundle to a fixed path should link THERE (grants are per app path) — **haus has no trill room yet**, so today that row is a plan, not a shipped path |
| the palette trill is themed with (source hex) | `nebelung` |
| DND / Focus toggling ("Hush") | `haus` (the layer) — trill only deep-links there. *Reading* which Focus is on is here (`Platform/FocusWatch`), and it is read-only by rule |
| the tunnel fronting the GitHub bridge (cloudflared, DNS, the org webhook) | `haus` (the layer) — trill only listens on localhost |
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
  `SQLITE_OPEN_READONLY`, schema-probed before every session — tables *and*
  the columns the reader reads — and disabled with a visible reason on any
  drift. It is opt-in, experimental, and the app must stay fully useful
  without it. No usernoted type or column name may appear outside
  `Providers/SystemMirror/`; everything crossing out is a `UsernotedRecord`,
  and every decision about it is `SystemMirrorMapper`'s and pure.
  Two things measured in the M3 spike are load-bearing and must not be
  "optimised" away. **A mirrored card is ~5.1 s late and that is usernoted's
  batching, not ours** — say the number, don't chase it; watching the `-wal`
  buys cost, not latency. And **trill never mirrors trill**: `ownBundleIDs`
  excludes the whole family by identity, because a mirror that reads its own
  banners draws, records, re-reads and draws again. Unlikely isn't good
  enough there; impossible is.
- **The calendar is read, never written, and never asked for unprompted.**
  `CalendarProvider` runs EventKit in-process — the OS pushes changes, so
  there is no poller — and draws one `note` per occurrence, `calendarLeadMinutes`
  before it starts. EventKit types stop at that provider the way usernoted's
  stop at System Mirror: everything crossing out is a `CalendarOccurrence`,
  and every decision (does this banner, when, what does it say, is that link
  really a meeting) is `CalendarEventMapper`'s and pure. The source is
  **off by default and the toggle is checked before anything asks macOS for
  permission** — trill never springs a Calendars prompt on a launch nobody
  asked anything of, and it holds no write access to ask with. The Join pill
  is drawn only for a **recognized conferencing host**: the first `https://`
  in someone's notes is as often a doc, and a pill that opens one is a lie in
  a button.
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
- **A resolver is named on the wire and *declared* in `rules.json`.** An
  `ask` can clear itself — `trill resolve`, an event carrying `resolves`, or
  a `--until` poller — but what that poller runs lives in the user's own
  rules file, runs as argv through `/usr/bin/env` with no shell anywhere,
  and takes wire arguments only into numbered holes (`$1`…`$9`, never a
  leading `-`). Any process on this Mac can write to trill's socket; a
  command string on the wire would make the daemon a run-this-on-a-timer
  service for all of them, in a session that may hold Full Disk Access.
  Resolution is also one-way: nothing may put an answered question back on
  screen, and a poller that gives up leaves the fin — trill never invents an
  answer it didn't get.
- **`trill ask` blocks the caller, never the compositor.** The one verb that
  answers late: the daemon holds the socket open and replies when a pill is
  pressed. `AskBroker` owns that — every ask resolves exactly once, first
  resolution wins, because a pill click answers *and then* takes the banner
  down. Nothing but a pressed pill is an answer: a timeout, a dismissal, a
  hangup, a question a rule kept off screen and one another process resolved
  all exit 75, never 0. `reply` actions are minted by the daemon, so no sender
  can ship a banner whose Deny answers 0 — and a fin restored from the ledge
  after a restart loses its pills, because the socket that could have carried
  that answer died with the last daemon.
- **A Focus is read, and it is a routing rule.** When macOS is in a Focus,
  `PolicyEngine` takes it as an input beside the clock (`SystemFocus`, from
  `FocusReader`) and quietens what would have bannered: chatter goes to the
  inbox, **faults still land**, and an `ask` goes **straight to the ledge** —
  because a question swallowed is a caller blocked forever, and the ledge is
  already where an unanswered one lives. `critical` punches through exactly
  as it does through quiet hours, and quiet hours have the last word over
  what a Focus decided. **trill never writes a Focus** — not the assertion
  store, not the pane, not a private API. Turning one on is the desktop's
  dial (haus's "Hush" lane) and the user's click; Settings deep-links there
  and stops. Two more things that cannot slip: the store is a *file*
  (`~/Library/DoNotDisturb/DB/Assertions.json`) so the reading has **three**
  verdicts — on, off, and *can't tell* — and can't-tell **fails open**,
  deciding exactly what no Focus decides; and only `storeAssertionRecords`
  says a Focus is on, never `storeInvalidationRecords`, which is a history of
  every Focus ever *ended* and would report one from March.
- **Shyness is ambient, and it is a rendering rule.** When macOS shows its
  in-use indicator (screen capture, camera or mic — one indicator, no way to
  tell them apart) or a display is mirrored, every card draws its redacted
  form. It is polled, never notified, because no API reports capture:
  `NSScreen.isCaptured` is UIKit's, `CGDisplayIsCaptured` died in 10.9, and
  nothing is posted when a capture starts — all measured, see
  `ARCHITECTURE.md`. Read the indicator's *geometry*, never its window name:
  `kCGWindowName` needs Screen Recording permission, and trill will not ask
  for the screen in order to be shy about the screen. The queue never learns
  any of this — no event is dropped, delayed, or stored differently.
- **The catch-up card fires on the way back in, and only then.** One low
  card on unlock — *while you were away — 2 asks, 1 fault, 14 notes* — counted
  by kind (asks lead; the digest ranks by size, this one by what you have to
  deal with), capped at a day back, and **not drawn at all when nothing
  landed**. Presence is *pushed*, unlike shyness: lock, unlock, sleep, wake
  and session switching are all posted, so `PresenceSentinel` listens and
  never reads the system. Two rules keep it honest. It **ignores quiet
  hours** — the one card that cannot interrupt anybody, because it only fires
  as somebody sits down — and it is a **tally, never a replay**: it re-draws
  no event, composes like `DigestCard` straight into the queue without
  re-entering the repository, and the click is a query (`InboxScope.since`)
  against rows that are already there.
- **A banner drawn at a locked screen was never seen.** `AppDatabase.insert`
  takes presence as well as the decision, so a card that played to an empty
  room is stored unread. Getting this wrong is how a whole night disappears
  from both the inbox's unread count and the catch-up card — and it can only
  be recorded at ingest, because nothing can work out afterwards who was
  sitting there.
- **The inbox is where the overflow goes, so it holds no state of its own.**
  The ledge evicts a sixth ask, a digest card is a count and quiet hours route
  events past the screen — all three land in `AppDatabase`, and the window is a
  view onto it through `InboxList` (scope, search, thread folding: pure, and
  tested without a display). It updates live off `InboxFeed`, never a poll or a
  Refresh button. Two things it must keep saying: **unread means trill never
  put this in front of you** — a banner drawn at somebody is stamped read on
  the way in; one drawn at a locked screen is not, and nor is anything held
  back — and **it never redacts**, because
  `--redact` and shyness are rules for cards drawn *at* someone and this window
  only exists because the user asked for it. It draws every performable action
  as a pill except `reply`: history has no socket to answer down.
- **A progress card is an update, not an arrival.** An event carrying
  `progress` (0…1) and a `key` takes over the card already wearing that key —
  it does not stack beside it and does not fold into it, because "+49" is a
  useless thing to say about one build. It is the *only* exception to "a
  re-send is a second arrival" besides the ledge's supersede. Ticks are drawn
  and never stored: `isProgressTick` keeps them out of the database and out of
  digest tallies, so the inbox holds the ending, not the fifty steps to it. It
  never replaces an `ask`, whatever key it carries — a question taken off
  screen with nobody told leaves its caller blocked forever — and a card the
  user swatted away hushes its own ticks until the ending. And
  nothing in the compositor knows what a build is — a card stays up because its
  sender keeps sending, so a driver that dies loses its card on the normal
  clock (`scripts/nix-progress.sh` is the reference driver, heartbeat included).
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

## Settings are a file

**`~/.config/trill/config.json` is the source of truth for every app-level
switch**, and Settings is a view onto it. A toggle writes the file; an edit to
the file moves the toggle, live, through the same watcher shape `rules.json`
uses. There is no second copy — UserDefaults holds only UI ephemera (the
window frame, the selected pane, the one-shot flags the Full Disk Access flow
arms across a relaunch).

Adding a switch means adding it to `AppConfig` in **both** directions —
`init(json:)` and `json` — and to a pane. Miss `json` and the switch moves
while the file never changes, so the value reverts the next time the file is
read; miss `init(json:)` and what someone typed into the file is ignored. A key
the file doesn't name is that key at its default; a partial config.json is the
normal case, not a broken one. Keys trill doesn't know are preserved verbatim
across writes.

The file is refused as read-only when it's a symlink into the Nix store —
i.e. this Mac's desktop generated it, and a rebuild would revert a click. Same
rule pounce applies to its own `config.json`; Settings says so rather than
moving a switch that won't stick.

## Layout (pounce/perch convention)

```text
Trill/
  App/           entry, composition root, settings (config.json-backed)
  CLI/           `trill send/ping` — same binary, CLI personality
  Domain/        NotificationEvent, RuleSet (+ FocusPolicy), PolicyEngine,
                 InboxList, Digest, CatchUp (all pure)
  Providers/     protocol + Socket · GitHub webhook · Calendar (EventKit)
                 + SystemMirror (quarantined)
  Repositories/  EventRepository actor: supervise, normalize, dedupe, fan out
                 + the two composed-card consumers (digest · catch-up)
  Persistence/   AppDatabase — trill's OWN sqlite; the only writer in the app
  Compositor/    ScreenGeometry (pure), BannerQueue, panels, window system
  Platform/      ActionRouter, SystemIntegration (all Apple hooks, one file),
                 ScreenWatch · PresenceWatch · FocusWatch (the ambient reads)
  UI/            BannerView, InboxView + InboxRowView, LedgeView,
                 Settings (View · Panes · Chrome)
TrillTests/      geometry, policy, pipeline, inbox, presence — no display
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

**No build ships coverage instrumentation — `ENABLE_CODE_COVERAGE = NO` in
both project-level configurations, and CI fails if a Release binary comes out
with `__llvm_prf_cnts` in it.** This project ships no *shared* scheme, so
`-scheme Trill` resolves whatever Xcode autocreated in `xcuserdata/`, whose
coverage default is YES — and that leaks past the test action into a plain
`build`. The consequence is not a slower binary: the app binary **is** the
`trill` CLI, `holt notify` execs it from every agent-pane hook, and LLVM's
profile runtime writes `default.profraw` into whatever cwd the process exits
in. That is one untracked file per agent worktree, and `holt reap` refuses to
reap a checkout with uncommitted work in it — so lanes pile up until someone
deletes files by hand. Want coverage for a run? Ask for it explicitly:
`xcodebuild test -enableCodeCoverage YES` overrides the setting. Don't turn it
back on in the project, and don't re-add `*.profraw` to `.gitignore` — a stray
one showing up in `git status` is the signal, not the noise.

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
