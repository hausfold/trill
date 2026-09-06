# AGENTS.md

**Trill** — a quiet, scriptable notification compositor for macOS: one Swift
binary that is both the daemon and the `trill` CLI, drawing its own silent
banners from local sources (the CLI socket; System Mirror, a read-only mirror of
Apple's `usernoted` store, behind a flag). One of the
[hausfold](https://github.com/hausfold) repos; stands alone like pounce and perch.

For an agent working *on* trill from a checkout, whichever client; wiring is in
[`.agents/`](./.agents/README.md). `docs/` is the manual and `README.md` a door
onto it; [`ARCHITECTURE.md`](./ARCHITECTURE.md) holds the invariants and their
measurements; [`PRD.md`](./PRD.md) is a plan, not a doc. Family rules and the
cross-repo table: the workshop's `AGENTS.md`.

## Routing

This repo owns the compositor — daemon, providers, rules engine, banner/inbox
UI, CLI — not how it is launched, themed at the source or packaged. A colour
hex, a launchd plist or a Focus toggle does not belong here even if it would
work.

| Want to change… | Repo |
|---|---|
| the app (compositor, providers, rules, CLI, inbox) | **here** |
| how trill is installed (flake wiring, launchd) | `haus` — `haus.notifications.compositor` copies the bundle to `/Applications/Trill.app` and ships its own `trill` wrapper; no second `bin/trill` |
| whether `trill` resolves on PATH | by install source: `nix/package.nix` ships `bin/trill`; `scripts/dev-install.sh` links into a directory on the login PATH; a script-less install is the app's `SystemIntegration.ensureCLILink`, which defers to anything already answering. Keep [`docs/install.md`](./docs/install.md)'s table honest |
| the palette (source hex) | `nebelung` |
| the family the text is set in | here — `fontFamily` in `config.json`, a `Font` only in `Trill/UI/AppFont.swift`; the name comes from the desktop (`haus.fonts.sans.name`), trill installs and validates no font |
| the mark — app icon, README banner | here: `assets/trill-icon-master.png`, `assets/trill-banner.png`, nebelung's `yellow` / `surface0` / `surface1` / `surface2` baked in — a palette change re-renders the master and the `Trill/Assets.xcassets/AppIcon.appiconset` slots ([`assets/README.md`](./assets/README.md)), and `~/.config/trill/theme.json` never reaches them. Keep the icon flat; macOS 26 adds inset, shadow and gloss |
| DND / Focus toggling ("Hush") | `haus` — trill deep-links there; *reading* the Focus is here (`Platform/FocusWatch`), read-only by rule |
| which calendars sync at all | Apple's Calendar / Internet Accounts — trill only reads what EventKit has |
| the tunnel fronting the GitHub bridge (cloudflared, DNS, the org webhook) | `haus` — trill listens on localhost only |
| how a family tool draws a line (`haus-notify`, pounce's `notify()`, `bench`, `scruff hook notify`) and falls back to Apple's banner without trill | that tool's repo, each with its own `--source`, the string `~/.config/trill/rules.json` matches on |
| the Homebrew cask (none yet; the `trill` token is free) | `homebrew-tap`, CI-owned |
| the release pin `nix/release.nix` | here, **CI-owned** — never hand-bump |

## The one rule that explains everything

**The compositor never blocks on, or trusts, a provider.** Each runs supervised
in its own task, speaks only `NotificationEvent`, reports `ProviderHealth` from
an explicit `probe()`, and fails closed into "off with a reason". The why and
the measurements are `ARCHITECTURE.md`'s; this is what the code keeps.

- Decisions are pure: `PolicyEngine` reads (event, rules, clock), no I/O; new
  delivery behaviour goes through `DeliveryDecision`, never an ad-hoc branch
  in the queue. **The queue is the truth; panels are disposable** — topology
  rebuilds re-render from `BannerQueue`; never park event state in a view.
- **No sound**, even for critical. **No notification content in logs** — ids
  and source slugs; `Logger` privacy annotations are load-bearing. **Never
  steal focus** — non-activating panels; only windows the user summoned take
  key.
- **System Mirror is quarantined.** `usernoted` is opened
  `SQLITE_OPEN_READONLY`, schema-probed every session, off with a visible
  reason on drift. No usernoted type or column name leaves
  `Providers/SystemMirror/`: a `UsernotedRecord` crosses, and every decision is
  `SystemMirrorMapper`'s and pure — `systemMirrorApps`'s three states (absent,
  a list, `[]`) through `SystemMirrorMapper.isAllowed` on the slug `rules.json`
  matches, unticked rows dropped after the watermark moves. A mirrored card is
  ~5.1 s late, usernoted's batching: say the number, don't chase it (the `-wal`
  buys cost, not latency). `ownBundleIDs` excludes the whole family — trill
  never mirrors trill.
- **The calendar is read, never written, never asked for unprompted.**
  `CalendarProvider` runs EventKit in-process (pushed, no poller), one `note`
  per occurrence `calendarLeadMinutes` ahead; a `CalendarOccurrence` crosses,
  every decision `CalendarEventMapper`'s and pure. Off by default, and the
  toggle is checked before anything asks macOS for permission. The Join pill
  needs a recognized conferencing host, never the first `https://`.
- **trill reads Apple's settings; it never writes them.** `trill doctor` and
  the "Silence Native Banners" helper decode the per-app store read-only
  (`Platform/NotificationSettingsAudit`) — no "fix it for me". On macOS 26 the
  store is `~/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist`;
  `com.apple.ncprefs` (same `apps` array, same `flags`) is a stale mirror.
  Only the corroborated bits — on-screen alert `1<<3`/`1<<4`, sound `1<<2`,
  allow-notifications `1<<25` — and **`1<<25` first**, since macOS freezes the
  others when the master switch is off; bit 29 is the "time-sensitive apps"
  list, not allow. Check the pane on the current macOS before touching the
  helper's demo (Tahoe: a Desktop checkbox plus Temporary/Persistent).
- **The audit has three verdicts — noisy, quiet, can't tell.** The container
  needs Full Disk Access; without it `readAll()` returns nil, `trill doctor`
  exits **5** (4 when it found noisy apps), Settings says "can't tell", the
  helper walks but confirms nothing. Never render can't-tell as "all quiet".
- **The helper advances on the user's word** — **Done** is the mechanism, the
  poll a bonus. `NotificationSettingsAudit.walkable` is the only door the
  walkthrough, **Silence…** and `doctor --notify` take: an app with no row
  (bit 7 — `com.apple.SoftwareUpdateNotification`) is a notice, never a step,
  and a `silenceNative` click resolving to nothing walkable opens the pane
  instead. On the Apps pane the tick is a request and the line under it a
  reading, **Silence…** is offered only on apps trill draws, and the list is
  `everyListedApp`, not `findings`.
- **A resolver is named on the wire and declared in `rules.json`.** An `ask`
  clears through `trill resolve`, an event carrying `resolves`, or a `--until`
  poller — argv through `/usr/bin/env`, no shell, wire arguments only into
  `$1`…`$9` (never a leading `-`), because any process can write the socket
  and the daemon may hold Full Disk Access. A poller that gives up leaves the
  fin.
- **`trill ask` blocks the caller, never the compositor.** `AskBroker`
  resolves each ask once, first wins; anything but a pressed pill exits 75,
  never 0. `reply` actions are minted by the daemon; a fin restored after a
  restart loses its pills.
- **A Focus is read, and it is a routing rule.** `PolicyEngine` takes
  `SystemFocus` (from `FocusReader`) beside the clock; `critical` punches
  through, quiet hours have the last word. trill never writes a Focus;
  Settings deep-links to haus's "Hush". The store is a file
  (`~/Library/DoNotDisturb/DB/Assertions.json`): three verdicts, can't-tell
  fails open, and only `storeAssertionRecords` says on —
  `storeInvalidationRecords` is history.
- **Shyness is ambient, a rendering rule.** Polled, never notified —
  `NSScreen.isCaptured` is UIKit's, `CGDisplayIsCaptured` died in 10.9. Read
  the indicator's geometry, never `kCGWindowName` (Screen Recording
  permission). The queue never learns any of it.
- **The catch-up card is a tally, never a replay.** Presence is pushed:
  `PresenceSentinel` listens, never reads. It ignores quiet hours, composes
  like `DigestCard` straight into the queue, and its click is a query
  (`InboxScope.since`). **A banner drawn at a locked screen was never seen**:
  `AppDatabase.insert` takes presence with the decision and stores it unread.
- **`trill history` is the read half of `send`, and a query.** `inbox` opens a
  window; `history` is the same bounded fetch plus `HistoryQuery.filter` (pure)
  over rows `EventRepository` already writes — no persistence of its own. Rows
  come unfolded; with `persistHistory` off it is `historyUnavailable`, exit
  **5**, not an empty list.
- **The inbox holds no state of its own.** Everything lands in `AppDatabase`;
  the window is `InboxList` (scope, search, folding — pure, tested without a
  display) live off `InboxFeed`, no poll. A banner drawn at somebody is
  stamped read on the way in. It never redacts — `--redact` and shyness are
  for cards drawn *at* someone — and every action is a pill except `reply`.
- **A progress card is an update, not an arrival.** `progress` (0…1) plus a
  `key` takes over the card wearing that key; `isProgressTick` keeps ticks out
  of the database and digest tallies; a tick never re-arms the clock — the
  card parks as a fin through `expire`, and a job's fin yields to a question
  when a sixth lands, comes down after `progressStallTimeout`, and is never
  written to the ledge store or restored. `scripts/nix-progress.sh` is the
  reference driver, heartbeat included.

## Settings are a file

**`~/.config/trill/config.json` is the source of truth for every app-level
switch**; Settings is a view onto it, live both ways through the watcher shape
`rules.json` uses. UserDefaults holds only UI ephemera (window frame, selected
pane, the one-shot flags the Full Disk Access flow arms across a relaunch).

- A switch goes into `AppConfig` both ways — `init(json:)` and `json` — and a
  pane. An unnamed key is its default; unknown keys survive writes verbatim.
- `systemMirrorApps`'s absence is a value: written once chosen, cleared through
  `AppConfig.absentKeys`, never tidied into an always-present array.
- `fontFamily` becomes a `Font` only in `Trill/UI/AppFont.swift`: a new `Text`
  takes `AppFont.caption`, never `.caption`. `.system(…)` stays on purpose in
  three places — `Image(systemName:)`, a deliberately `.monospaced()` run, and
  the helper's System Settings replica.
- A `config.json` symlinked into the Nix store is refused read-only, and
  Settings says so — a rebuild would revert the click.

## Layout (pounce/perch convention)

```text
Trill/
  App/           entry, composition root, settings (config.json-backed)
  CLI/           `trill send/ask/history/skill/…` — same binary, CLI personality
                 (EmbeddedSkills.swift is GENERATED — scripts/generate-skills.sh)
  Domain/        NotificationEvent, RuleSet (+ FocusPolicy), PolicyEngine,
                 InboxList, HistoryQuery, Digest, CatchUp (all pure)
  Providers/     protocol + Socket · GitHub webhook · Calendar (EventKit)
                 + SystemMirror (quarantined)
  Repositories/  EventRepository actor: supervise, normalize, dedupe, fan out
                 + the two composed-card consumers (digest · catch-up)
  Persistence/   AppDatabase — trill's OWN sqlite; the only writer in the app
  Compositor/    ScreenGeometry (pure), BannerQueue, panels, window system
  Platform/      ActionRouter, SystemIntegration (all Apple hooks, one file),
                 ScreenWatch · PresenceWatch · FocusWatch (the ambient reads)
  UI/            BannerView, InboxView + InboxRowView, LedgeView,
                 Settings (View · Panes · Chrome) — Apps pane is the picker
                 + AppFont, the one seam between `fontFamily` and a `Font`
TrillTests/      geometry, policy, pipeline, inbox, history, presence — no display
```

## The agent surface (`ai/SKILL.md`)

[`ai/SKILL.md`](./ai/SKILL.md) is for an agent *using* trill with no checkout:
the verbs, the six exit codes, the rules file, when the answer is something
else. Bound by the workshop's
[`docs/agent-surface.md`](https://github.com/hausfold/workshop/blob/main/docs/agent-surface.md):
≤150 lines, no flag dumps (that's `trill help`), a `description` naming the
phrases a user says, not trill's features.

- Three invariants must survive into it: **no sound**; **trill reads Apple's
  notification settings and never writes them** (`doctor` names, the user
  clicks); exit **5** is *can't tell*, never "all quiet".
- **The binary ships it (A3).** `trill skill` prints it, `trill skill install`
  writes it into every agent client found — the standalone user's door.
  `scripts/generate-skills.sh` bakes `ai/**/SKILL.md` into
  `Trill/CLI/EmbeddedSkills.swift`, which is **committed**;
  `scripts/check-skills.sh` diffs a fresh regeneration against it. `install`
  never clobbers: a differing file is left alone, exit 3; a symlink is haus's,
  named, exit 0; `--dir` with `--client`, or either flag without a value, is
  usage.
- `nix/skill.nix` ships the prose as `pkgs.trill-skill` (`$out/trill/SKILL.md`)
  and runs the same guard on the frontmatter alone. haus installs it
  (`modules/ai/tool-skills.nix`, gated on `haus.notifications.compositor`), so
  **a rename here is a red rebuild there** — its `.#tool-skills` check,
  Mac-only — until haus's list moves with the lock bump.
- trill is a flake input of haus and `OVERRIDABLE`, never one of `bench`'s
  `FAMILY` repos: it lands through its own PRs, and `bench release trill` is
  its only bench verb.
- **Every claim in it must be runnable** — a verb, flag or exit code changes in
  the same PR as `ai/SKILL.md`.

## Verifying

`xcodebuild -project Trill.xcodeproj -scheme Trill test`, or let CI. Geometry,
policy, queue and wire format are testable headless — keep anything that can be
a pure function with a test that way. Feel-testing banners needs a real session:
build, run, `trill send`.

- **Edited a SKILL.md? Run `scripts/generate-skills.sh` and commit both
  files.** The guard is
  `scripts/check-skills.sh ai Trill/CLI/EmbeddedSkills.swift scripts/generate-skills.sh`;
  `build.yml` runs it first.
- **Debug builds carry `com.hausfold.trill.debug` and their own
  `Application Support/Trill (debug)` — leave both.** TCC keys Full Disk Access
  by bundle id and rewrites the row to whichever binary asked last, and
  `kTCCServiceSystemPolicyAllFiles` never prompts: sharing `com.hausfold.trill`
  would let every `xcodebuild test` silently revoke the installed app's grant.
- **No build ships coverage instrumentation.** `ENABLE_CODE_COVERAGE = NO` in
  both project-level configurations; CI fails a Release binary carrying
  `__llvm_prf_cnts` (`scripts/assert-no-instrumentation.sh`). The binary is
  the `trill` CLI that `scruff notify` execs from every agent-pane hook; an
  instrumented one drops `default.profraw` into each worktree, which
  `scruff reap` then refuses. One run's coverage:
  `xcodebuild test -enableCodeCoverage YES`. Don't re-add `*.profraw` to
  `.gitignore` — a stray one in `git status` is the signal.
- **Feel-test with `scripts/dev-install.sh`, not a bare `xcodebuild`.** A
  `CODE_SIGNING_ALLOWED=NO` build is ad-hoc signed and macOS pins its Full Disk
  Access grant to the cdhash, so it revokes itself next build. The script signs
  with the Developer ID, unregisters stray `Trill.app` copies and installs one
  at `~/Applications/Trill.app`; pass `--reset-permissions` once after an
  ad-hoc build. It stays out of snug with the family's other maintenance
  scripts — the workshop's CLI-standard row owns that.
- **Releases** are `bench release trill` from the workshop: a CalVer tag
  `v<date>` matching `VERSION`, CI builds the notarized ZIP and rewrites
  `nix/release.nix` (and the cask, once there is one). Never hand-type a
  version or hand-bump the pin.
- Cloud sessions edit and plan tests only; `xcodebuild` and feel-testing are
  macOS-local. `.agents/setup.sh` puts Nix on a bare container so the flake
  resolves; it cannot build a macOS app.
