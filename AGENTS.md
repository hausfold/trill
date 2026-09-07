# AGENTS.md

**Trill** — a quiet, scriptable notification compositor for macOS: one Swift
binary that is both the daemon and the `trill` CLI, drawing its own silent
banners from local sources (the CLI socket; System Mirror, a read-only mirror of
Apple's `usernoted` store, behind a flag). A [hausfold](https://github.com/hausfold)
repo that stands alone, like pounce and perch.

Per-client wiring is in [`.agents/`](./.agents/README.md). `docs/` is the
manual and `README.md` a door onto it; [`ARCHITECTURE.md`](./ARCHITECTURE.md)
holds the invariants with their reasoning and measurements; [`PRD.md`](./PRD.md)
is a plan, not a doc. Family rules and the cross-repo table: the workshop's
`AGENTS.md`.

## Routing

This repo owns the compositor — daemon, providers, rules engine, banner/inbox
UI, CLI — and not how it is launched, themed at the source or packaged, even
where that would work.

| Want to change… | Repo |
|---|---|
| the app (compositor, providers, rules, CLI, inbox) | **here** |
| how trill is installed (flake wiring, launchd) | `haus` — `haus.notifications.compositor` copies the bundle to `/Applications/Trill.app` and ships its own `trill` wrapper; no second `bin/trill` |
| whether `trill` resolves on PATH | by install source: `nix/package.nix` ships `bin/trill`, `scripts/dev-install.sh` links into a login-PATH directory, and a script-less install is `SystemIntegration.ensureCLILink`, which defers to anything already answering. Keep [`docs/install.md`](./docs/install.md)'s table honest |
| the palette (source hex) | `nebelung` |
| the family the text is set in | here — `fontFamily` in `config.json`; the name comes from the desktop (`haus.fonts.sans.name`), and trill installs and validates no font |
| the mark — app icon, README banner | here: `assets/trill-icon-master.png`, `assets/trill-banner.png`, nebelung's `yellow` / `surface0` / `surface1` / `surface2` baked in, so a palette change re-renders the master and the `Trill/Assets.xcassets/AppIcon.appiconset` slots ([`assets/README.md`](./assets/README.md)); the banner has no source here and is redrawn from the brand kit. `~/.config/trill/theme.json` never reaches them. Keep the icon flat; macOS 26 adds inset, shadow, gloss |
| DND / Focus toggling ("Hush") | `haus`, deep-linked from Settings; *reading* the Focus is here (`Platform/FocusWatch`) |
| which calendars sync at all | Apple's Calendar / Internet Accounts — trill reads only what EventKit has |
| the tunnel fronting the GitHub bridge (cloudflared, DNS, the org webhook) | `haus` — trill listens on localhost only |
| how a family tool draws a line (`haus-notify`, pounce's `notify()`, `bench`, `scruff hook notify`) and falls back to Apple's banner without trill | that tool's repo, each with its own `--source`, the string `~/.config/trill/rules.json` matches on |
| the Homebrew cask (none yet; the `trill` token is free) | `homebrew-tap`, CI-owned |
| the release pin `nix/release.nix` | here, **CI-owned** — never hand-bump |

## The one rule that explains everything

**The compositor never blocks on, or trusts, a provider.** Each runs supervised
in its own task, speaks only `NotificationEvent`, reports `ProviderHealth` from
an explicit `probe()`, and fails closed into "off with a reason".

What follows is the identifiers, numbers and refusals the code must keep. Why
each holds, and what it was measured against, is `ARCHITECTURE.md`'s fourteen
invariants and its hard cases — read that before changing one.

- **Decisions are pure.** `PolicyEngine` over (event, rules, clock), no I/O;
  delivery behaviour through `DeliveryDecision`, never an ad-hoc branch in the
  queue. `BannerQueue` is the truth — topology rebuilds re-render from it, and
  no view holds event state.
- **No sound**, even for critical. **No notification content in logs** — ids and
  source slugs; `Logger` privacy annotations are load-bearing. **Never steal
  focus**: non-activating panels, and only a window the user summoned takes key.
- **System Mirror is quarantined.** `SQLITE_OPEN_READONLY`, schema-probed every
  session — tables *and* the columns the reader reads — off with a visible
  reason on drift; opt-in and experimental, and the app stays fully useful
  without it. No usernoted type or column name
  out of `Providers/SystemMirror/` (a `UsernotedRecord` crosses); every decision
  `SystemMirrorMapper`'s and pure. `systemMirrorApps` is absent, a list, or `[]`, read through
  `SystemMirrorMapper.isAllowed` on the slug `rules.json` matches, unticked rows
  dropped after the watermark. ~5.1 s late on usernoted's batching — state the
  number, don't chase it. `ownBundleIDs` excludes the whole family.
- **The calendar is read, never written, never asked for unprompted.**
  `CalendarProvider`, EventKit in-process and pushed; one `note` per
  `CalendarOccurrence` `calendarLeadMinutes` ahead; every decision
  `CalendarEventMapper`'s and pure.
  Off by default, toggle checked before macOS is asked for permission. The Join
  pill needs a recognized conferencing host, never the first `https://`.
- **trill reads Apple's notification settings; it never writes them.** `trill
  doctor` and the "Silence Native Banners" helper decode the per-app store
  read-only through `Platform/NotificationSettingsAudit` — no "fix it for me".
  The store on macOS 26 is
  `~/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist`;
  `com.apple.ncprefs` is a stale mirror of the same `apps` and `flags`.
  Corroborated bits only — alert `1<<3`/`1<<4`, sound `1<<2`, allow `1<<25`,
  and **`1<<25` first**, the rest freezing while it is off; bit 29 is the
  time-sensitive list, not allow. Re-check the pane on the current macOS before
  touching the helper's demo.
- **Three verdicts — noisy, quiet, can't tell; never can't-tell as "all
  quiet".** No Full Disk Access means `readAll()` is nil, `trill doctor` exits
  **5** (**4** on noisy apps) and Settings says "can't tell". The helper
  advances on the user's **Done**, the poll a bonus, and
  `NotificationSettingsAudit.walkable` is the only door the walkthrough,
  **Silence…** and `doctor --notify` take: no row (bit 7,
  `com.apple.SoftwareUpdateNotification`) is a notice, never a step, and a
  `silenceNative` click with nothing walkable opens the pane. The tick is a
  *request* and the line under it a *reading* — a row goes green because the
  audit says macOS is quiet, never because the switch moved. **Silence… is
  offered only on apps trill draws.** The Apps pane
  lists `everyListedApp`, not `findings`.
- **A resolver is named on the wire and declared in `rules.json`.** An `ask`
  clears through `trill resolve`, an event carrying `resolves`, or a `--until`
  poller: argv via `/usr/bin/env`, no shell, wire arguments only into
  `$1`…`$9`, never a leading `-`; a poller that gives up leaves the fin.
  **`trill ask` blocks the caller, never the compositor** — `AskBroker` resolves
  once, first wins, and anything but a pressed pill exits **75**. Resolution is
  one-way: nothing puts an answered question back on screen. `reply`
  actions are daemon-minted; a fin restored after a restart loses its pills.
- **A Focus is read, never written, and it is a routing rule.** `PolicyEngine`
  takes `SystemFocus` (`FocusReader`) beside the clock: chatter goes to the
  inbox, **faults still land**, and an `ask` goes **straight to the ledge** — a
  question swallowed is a caller blocked forever. `critical` punches
  through, quiet hours have the last word.
  `~/Library/DoNotDisturb/DB/Assertions.json`, the same three verdicts,
  can't-tell failing open, and only `storeAssertionRecords` says on —
  `storeInvalidationRecords` is history.
- **Shyness is ambient, a rendering rule.** Screen capture, camera or mic (one
  indicator, no telling them apart) or a mirrored display, and every card draws
  its **redacted form**. Polled, never notified, because no API reports
  capture: `NSScreen.isCaptured` is UIKit's and `CGDisplayIsCaptured` died in
  10.9. Read the indicator's *geometry*, never `kCGWindowName` (Screen
  Recording permission). The queue never learns it.
- **The catch-up card is a tally, never a replay.** One low card on unlock and
  only then, counted by kind (asks lead), capped at a day back, and **not drawn
  at all when nothing landed**. `PresenceSentinel` listens,
  never reads; ignores quiet hours; composes like `DigestCard` into the queue;
  its click is a query (`InboxScope.since`). **A banner drawn at a locked screen
  was never seen** — `AppDatabase.insert` stores it unread with the decision.
- **The read side holds no state of its own.** `inbox` opens a window;
  `trill history` is the same bounded fetch plus `HistoryQuery.filter` (pure)
  over `EventRepository`'s rows, returned unfolded — with `persistHistory` off
  it is `historyUnavailable`, exit **5**, not an empty list. `InboxList` (scope,
  search, folding — pure, tested with no display) lives off `InboxFeed`, no
  poll, and a banner drawn at somebody is stamped read on the way in. The inbox
  never redacts (`--redact` and shyness are for cards drawn *at* someone); every
  action is a pill except `reply`.
- **A progress card is an update, not an arrival.** `progress` (0…1) plus a
  `key` takes over the card wearing that key — the only exception to **a
  re-send is a second arrival** besides the ledge's supersede. It never
  replaces an `ask`, whatever key it carries. `isProgressTick` keeps ticks out
  of the database and digest tallies; a tick never re-arms the clock; a card
  the user swatted hushes its own ticks until the ending. The card
  parks as a fin through `expire`, later ticks fill it in place, it yields to a
  question when a sixth lands, comes down after `progressStallTimeout`, and is
  never written to the ledge store or restored; **the ending takes it down and
  draws the one card worth drawing**. `scripts/nix-progress.sh` is the
  reference driver, heartbeat included.

## Settings are a file

**`~/.config/trill/config.json` is the source of truth for every app-level
switch**; Settings is a view onto it, live both ways through the watcher shape
`rules.json` uses. UserDefaults holds only UI ephemera — window frame, selected
pane, the one-shot flags the Full Disk Access flow arms across a relaunch. A
`config.json` symlinked into the Nix store is refused read-only, and Settings
says so.

- A switch goes into `AppConfig` both ways (`init(json:)` and `json`) and a
  pane. An unnamed key is its default; unknown keys survive writes verbatim.
- `systemMirrorApps`'s absence is a value: written once chosen, cleared through
  `AppConfig.absentKeys`, never tidied into an always-present array.
- `fontFamily` becomes a `Font` only in `Trill/UI/AppFont.swift` — a new `Text`
  takes `AppFont.caption`, never `.caption`. `.system(…)` stays on purpose in
  three places: `Image(systemName:)`, a deliberately `.monospaced()` run, and
  the helper's System Settings replica.

## Layout (pounce/perch convention)

```text
Trill/
  App/           entry, composition root, settings
  CLI/           `trill send/ask/resolve/history/inbox/doctor/skill/…`, same
                 binary (EmbeddedSkills.swift is GENERATED)
  Domain/        NotificationEvent, RuleSet (+ FocusPolicy), PolicyEngine,
                 InboxList, HistoryQuery, Digest, CatchUp — all pure
  Providers/     Socket · GitHub webhook · Calendar · SystemMirror
  Repositories/  EventRepository actor + the digest and catch-up consumers
  Persistence/   AppDatabase — trill's OWN sqlite, the app's only writer
  Compositor/    ScreenGeometry (pure), BannerQueue, panels, window system
  Platform/      ActionRouter, SystemIntegration (all Apple hooks, one file),
                 ScreenWatch · PresenceWatch · FocusWatch
  UI/            BannerView, InboxView, LedgeView, Settings, AppFont
TrillTests/      geometry, policy, pipeline, inbox, history, presence — no display
```

## The agent surface (`ai/SKILL.md`)

[`ai/SKILL.md`](./ai/SKILL.md) is for an agent *using* trill with no checkout:
the verbs, the six exit codes, the rules file, when the answer is something
else. Bound by the workshop's
[`docs/agent-surface.md`](https://github.com/hausfold/workshop/blob/main/docs/agent-surface.md):
≤150 lines, no flag dumps (that's `trill help`), a `description` naming the
phrases a user says. Three invariants must survive into it — **no sound**,
**read-never-write**, and exit **5** as *can't tell* rather than "all quiet" —
and every claim must be runnable, so a verb, flag or exit code changes in the
same PR as `ai/SKILL.md`.

- **The binary ships it (A3).** `trill skill` prints it, `trill skill install`
  writes it into every agent client found — the standalone user's door.
  `scripts/generate-skills.sh` bakes `ai/**/SKILL.md` into
  `Trill/CLI/EmbeddedSkills.swift`, which is **committed**;
  `scripts/check-skills.sh` diffs a fresh regeneration against it. `install`
  never clobbers: a differing file is left alone, exit 3; a symlink is haus's,
  named rather than met with an `EPERM`, exit 0; `--dir` with `--client`, or
  either flag without a value, is usage.
- `nix/skill.nix` ships the prose as `pkgs.trill-skill` (`$out/trill/SKILL.md`)
  and runs the same guard on the frontmatter alone. haus installs it
  (`modules/ai/tool-skills.nix`, gated on `haus.notifications.compositor`), so
  **a rename here is a red rebuild there** — its `.#tool-skills` check, Mac-only
  — until haus's list moves with the lock bump.
- trill is a flake input of haus and `OVERRIDABLE`, never one of `bench`'s
  `FAMILY` repos: it lands through its own PRs, and `bench release trill` is its
  only bench verb.

## Verifying

`xcodebuild -project Trill.xcodeproj -scheme Trill test`, or let CI. Geometry,
policy, queue and wire format are testable headless — keep anything that can be
a pure function that way. Feel-testing banners needs a real session: build, run,
`trill send`.

- **Edited a SKILL.md? Run `scripts/generate-skills.sh` and commit both files.**
  `build.yml` runs the guard first:
  `scripts/check-skills.sh ai Trill/CLI/EmbeddedSkills.swift scripts/generate-skills.sh`.
- **Debug builds carry `com.hausfold.trill.debug` and their own
  `Application Support/Trill (debug)` — leave both.** TCC keys Full Disk Access
  by bundle id and `kTCCServiceSystemPolicyAllFiles` never prompts, so sharing
  `com.hausfold.trill` lets every `xcodebuild test` silently revoke the
  installed app's grant.
- **No build ships coverage instrumentation.** `ENABLE_CODE_COVERAGE = NO` in
  both project-level configurations, and CI fails a Release binary carrying
  `__llvm_prf_cnts` — `scripts/assert-no-instrumentation.sh`'s header carries
  the rest (no *shared* scheme, so `-scheme Trill` resolves `xcuserdata/`'s,
  whose default is YES; `scruff notify` execs this binary, and `default.profraw`
  in a worktree is one `scruff reap` refuses). One run's coverage:
  `xcodebuild test -enableCodeCoverage YES`. Don't re-add `*.profraw` to
  `.gitignore` — a stray one in `git status` is the signal.
- **Feel-test with `scripts/dev-install.sh`, not a bare `xcodebuild`.** A
  `CODE_SIGNING_ALLOWED=NO` build is ad-hoc signed and macOS pins Full Disk
  Access to the cdhash, so it revokes itself next build. The script signs with
  the Developer ID, unregisters stray `Trill.app` copies and installs one at
  `~/Applications/Trill.app`; pass `--reset-permissions` once after an ad-hoc
  build. It stays out of snug with the family's other maintenance scripts — the
  workshop's CLI-standard row owns that.
- **Releases** are `bench release trill` from the workshop: a CalVer tag
  `v<date>` matching `VERSION`, CI builds the notarized ZIP and rewrites
  `nix/release.nix` (and the cask, once there is one). Never hand-type a version
  or hand-bump the pin.
- Cloud sessions edit and plan tests only. `.agents/setup.sh` puts Nix on a bare
  container so the flake resolves; it cannot build a macOS app.
