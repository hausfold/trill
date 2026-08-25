# Trill v1 product requirements

## Promise

Any local source — a shell script, a nix rebuild, pounce, CI — can put a
quiet, beautiful banner on screen with one line, and the user controls what
interrupts them with a few declarative rules. No sound, ever. What we own,
we own completely; what Apple owns, we mirror honestly or link to honestly.

**Bad promise we are not making:** "a drop-in replacement for macOS
Notification Center with perfect compatibility."

## Milestones

### M1 — renderer + first-party pipeline (v1 gate)

- `LSUIElement` daemon + status item; same binary is the `trill` CLI.
- Unix-socket ingest (owner-only perms), versioned JSON-lines wire format.
- `trill send` (flags + `--json` stdin), `trill ping`; exit codes 0/1/2/3.
- Normalization, dedupe window, app-owned sqlite history with retention
  prune and an "off" switch.
- rules.json: banner / inbox / digest / drop, quiet hours, critical
  punch-through; hot reload; malformed file keeps last good rules.
- Banner compositor: panel per banner, all Spaces + over fullscreen, never
  key; top-right stack — a spaced column, as many cards as the screen fits,
  a "⌄ N waiting" badge when the queue holds more; hover pause; burst
  coalescing by thread, folded into one card that opens into a list on
  hover; Reduce Motion respected; redacted privacy level.
- Inbox window + minimal settings (login item, persistence, provider
  health, deep links to Apple's Notification/Focus settings).
- `trill doctor [--all] [--notify] [--json]`: reads Apple's per-app
  notification preferences read-only and reports the listed apps macOS
  still banners or sounds itself (exit 4 when any). `--notify` reports as
  banners whose one action opens a stepped helper panel beside System
  Settings — animated, live-polled, one app at a time. trill never writes
  another app's settings.

### M1.5 — semantic banners (the kind refactor)

- `kind` on the event (`ask/fault/chat/pulse/done/note`): what it asks of
  the reader. Kind owns the banner's hue (glyph chip, count pill, action
  pills), urgency owns the weight (low dims, critical fills the chip and
  tints the border). Unlabeled critical events read as `fault`, so old
  senders keep their old red.
- Hues arrive via `~/.config/trill/theme.json` (nebelung owns the hex; haus
  writes the file); system-color fallbacks otherwise.
- 2–3 performable actions draw as a pill row; the first is what the card
  click runs. One action stays an inline label. `trill send` grows `--kind`
  and repeatable `--action "Label=URL|app:bundle.id"`.
- Screen-true capacity (the `min(3)` clamp is gone), 8pt gaps instead of
  the 6pt lap, urgency-ordered waiting line, overflow badge.

### M1.6 — the Ledge (unattended asks)

- An `ask` banner whose dismiss clock runs out parks instead of vanishing:
  a slim kind-hued fin flush to the right screen edge, the group vertically
  centered, zero motion while parked. Hovering a fin slides the full card
  back out — pills live — and answering or dismissing removes it. A user's
  own dismissal never parks; only the clock does.
- At most 5 park; a sixth evicts the oldest (it survives in the inbox like
  every delivered event). Parked state is a third bucket in `BannerQueue`
  beside visible/waiting — fins are disposable panels rebuilt from it on
  every topology change.
- `trill inbox [--asks]` opens the inbox window over the socket, optionally
  filtered to `ask` events — the deep link a hot corner (haus's wiring, not
  trill's) calls.

### M1.7 — GitHub bridge (webhook ingest)

- GitHub events become trill events, seconds after they happen: webhooks →
  a tunnel (cloudflared against `hausfold.co`, haus's wiring) → a localhost
  HTTP receiver inside the daemon (`Providers/GitHub/`). Webhooks over
  polling because latency is the point.
- Mapping is the product: `review_requested` for the configured login →
  `ask` (parks on the Ledge), a red `workflow_run` → `fault`, green →
  `done`, a run gated on approval → `ask`, an `@login` mention → `chat`,
  the PR lifecycle — opened/reopened → `note`, merged → `done`, closed
  unmerged → `note` — and a submitted `pull_request_review` — approved →
  `done`, changes requested → `ask`, comment-only → `chat`. Those last two
  groups are unfiltered by actor, because agent lanes open PRs as the user
  and that's the signal. Everything else (synchronize, labels, edits,
  dismissed reviews) maps to nothing — the bridge banners only what the kinds can say
  honestly.
- Auth is the webhook's HMAC secret and nothing else: trill holds no GitHub
  token, **never writes GitHub state**, and 401s any delivery that doesn't
  verify. Config is one owner-read file, `~/.config/trill/github.json`
  (`{secret, login, port?}`).
- Dedupe is the delivery GUID (`github:<X-GitHub-Delivery>`): redeliveries
  and tunnel retries collide in the repository's id window by construction.
- Off with a reason, like every provider: missing config, taken port, or
  the Settings toggle — each is a visible health line, never a broken
  pipeline. Payload content never reaches logs; delivery ids, event names,
  and repo slugs only.

### M1.8 — resolution (asks that answer themselves)

- A parked ask can leave the ledge without a human: `trill resolve KEY`
  from anywhere, an event carrying `resolves` (the GitHub bridge takes its
  own review-request fin down the moment the PR merges or closes, and a
  finished run answers the one that was gated on approval), or a poller the
  daemon runs for the ask while it sits there.
- **The wire may name a resolver, never describe one.** `--until NAME[:args]`
  picks one out of a `resolvers` map in `~/.config/trill/rules.json`; the
  argv or URL behind that name lives in the user's own file. Anything local
  can write to trill's socket, so a command string on the wire would make
  the daemon a run-this-on-a-timer service for every process on the Mac.
  argv is argv — there is no shell anywhere in the path — arguments fill
  numbered holes (`$1`…`$9`) and may not start with `-`.
- Bounded and one-way: `every`/`timeout`/`giveUpAfter` are clamped on
  decode, `giveUpAfter` counts from when the question was *asked* so a
  relaunch can't extend it, five consecutive failures stop the poller, and
  nothing in the path can put a resolved question back on screen. A poller
  that gives up leaves the fin — trill never invents an answer it didn't
  get.
- `--key` names an ask so something *else* can resolve it later; the id
  `trill send` printed already works, so a key is only needed when the
  resolver is a different process. Re-sending an ask with the same key
  replaces its fin rather than growing a second one.
- The ledge itself survives a daemon restart (its own table in trill's
  sqlite, rewritten wholesale on every change, pruned at a week). A
  question that can evaporate on a crash is the failure the Ledge exists to
  end.

### M2 — rules that earn the name

Digest flushing on schedule — **shipped**: a `digest` rule tallies quietly and
drains on the hour as one card per digest name ("9 quiet things · ci ×4,
garden ×3") whose click opens the inbox scoped to exactly those events; quiet
hours hold the flush rather than skipping it. Still open: per-digest cadences,
per-source styling hooks, `trill history --source X --since 2h`, `trill watch
--json`, pounce integration, Hush handshake (enable Focus profile ↔ trill
takeover), opt-in command hooks for banner *actions* (a click running a
declared command, the way `--until` already runs a declared check).

### M3 — System Mirror feasibility spike (measure, then decide)

Read `~/Library/Group Containers/group.com.apple.usernoted/db2/db` under
Full Disk Access and answer with numbers, per macOS version (Sonoma →
current):

1. Do records appear promptly on delivery? Via WAL watching or only polling?
2. What lands under an active Focus? When banners are disabled per-app?
3. Which fields survive for Slack, Mail, Calendar, browsers, system?
4. Can destination/bundle metadata reliably open the right place?
5. How aggressively are rows pruned?

Ship System Mirror as opt-in experimental only if the answers support it;
otherwise it stays a power-user module and trill remains the first-party
layer. Either result is a success — the decision is the deliverable.

### M4 — provider actions

Chat open-conversation/reply, calendar open-event, GitHub open-PR, shell
retry/logs — capability-advertised per provider, never generic promises.

## Acceptance checks (M1)

1. `trill send --title hello` with the daemon running: banner appears
   top-right within 150 ms, silent, and auto-dismisses; the event is in the
   inbox afterward.
2. Send 10 events sharing `--thread` inside 10 s: one banner, "+9 more",
   newest title on its face. Hover it: the card opens downward into the
   folded thread-mates, newest first, and **all nine** are listed — a normal
   burst is never truncated on a normal display, because the row count comes
   from the screen and not from a constant. Cards below it move down, and are
   allowed to be pushed off screen entirely; they come back on unhover, which
   also closes the card and restarts the dismiss clock. Each row highlights
   under the pointer and clicks through to *its own* event's action, taking
   the whole banner with it; a row whose event goes nowhere doesn't highlight
   and doesn't click. Now send 200 on that thread: the card fills the space
   it has, ends in "and N earlier", and is never taller than the display.
3. Hover a banner: it stays; unhover: rotation resumes.
4. `rules.json` routing a source to `drop` takes effect on the next event
   after save, no restart.
5. Quiet hours active: normal events go inbox-only; `--urgency critical`
   still draws a banner.
6. Unplug the external display while three banners are up: survivors
   re-render on the remaining screen; nothing is lost.
7. Kill -9 the daemon and relaunch: history intact; a stale socket file
   does not prevent startup (a *live* second instance is refused).
8. `trill send` with no daemon: exit code 2 and a one-line stderr.
9. Full-screen a video: banners appear over it without stealing focus or a
   keystroke.
10. Reduce Motion on: banners appear with no offset animation.
11. Toggle "keep history" off: no new rows in trill.db (and no other file
    grows) while banners keep working.
12. No sound plays for any event, including critical.
13. Tick **Desktop** and **Play sound** for an app in System Settings, then
    run `trill doctor --all`: it names that app and exits 4. Run
    `trill doctor --notify` and click the banner: System Settings opens with
    the helper beside it, showing that app's row to look for. Untick Desktop
    and turn the sound off — the panel ticks it off within a second,
    unprompted, and closes. `trill doctor` now exits 0. Nothing trill did
    wrote the setting.
14. Switch an app's "Allow notifications" off entirely: `trill doctor` stops
    naming it, even though its Desktop and sound bits are still set.
15. Send `trill send --title "lane blocked" --kind ask --action
    "Open=https://…"` and let the banner time out: a slim fin appears
    mid-right on the screen edge, motionless. Hover it: the full card
    slides out with its pills live; click a pill — the fin is gone. Send
    six asks and let them all park: five fins, and the first ask is only
    in the inbox (`trill inbox --asks` opens it filtered). A `note` timing
    out parks nothing.
16. Send three events from three different `--source`s: three cards flush to
    the same right edge, 8pt apart, each with its own complete shadow, all
    three fully readable. Keep sending: cards keep stacking until the screen
    is out of room, and only then does the queue hold events back — with a
    "⌄ N waiting" badge under the bottom card admitting it.
17. Run `trill ask "Push to origin?" --pill Allow --pill Deny` in a terminal:
    the command blocks and an `ask` banner appears with both pills. Click
    **Deny** — the banner goes, the command exits **1** and prints `Deny`;
    click **Allow** instead and it exits **0**. Clicking the card's *title*
    presses nothing, because a question with two answers has no default one.
    Let a second one time out unattended: it parks as a fin, the command is
    still blocked, and answering from the hovered card ends it. Dismiss a
    third with the ✕: exit **75**, not 0 — silence is never consent. Ctrl-C a
    fourth: the banner disappears with the caller. Run one with `--timeout 5`
    and walk away: exit 75 and the banner takes itself down. Run one with
    `--key gate` and `trill resolve gate` from another terminal: the fin goes
    and the blocked command exits 75 — resolution unblocks, it never answers.

## Non-goals (v1)

- Capturing other apps' notifications (that's M3's question, not v1's
  promise).
- Suppressing Apple's banners programmatically.
- Invoking arbitrary notification action buttons of other apps.
- Windows/Linux, cloud sync, accounts, telemetry.
