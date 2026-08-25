<div align="center">

<!-- identity banner to come: assets/trill-banner-rounded.png -->

# trill

**no noise, just a trill**

your notifications, without the noise — a native, local, scriptable visual layer for macOS.

![part of hausfold](https://img.shields.io/badge/part_of-hausfold-f2c4e5?labelColor=202020)
![themed by nebelung](https://img.shields.io/badge/themed_by-nebelung-c9a8f1?labelColor=202020)
![license](https://img.shields.io/badge/license-MIT-d7d7d7?labelColor=202020)

<sub>**pre-release** · trill is still in the incubator. every path that could lose your work is either reversible by design or stops to ask you first — that's the intent, not a warranty. run it on a machine you can afford to rebuild, and tell us what breaks.</sub>

</div>

---

A cat doesn't meow at everything. A trill is the small chirred note it makes in
passing — enough to register that something happened, not enough to stop anyone's
afternoon. That's trill: a quiet notification compositor that draws small, flat,
silent banners — and gives every script, tool, and haus app one visual
language for "something happened."

It is **not** a drop-in replacement for Notification Center, because Apple
doesn't sell that entitlement. It's the honest version: a compositor trill
fully owns, fed by providers — your own tools cleanly today, mirrored system
notifications experimentally tomorrow.

## why trill

- **scriptable end to end** — `trill send --title "deploy landed"` from any
  shell, CI job, or nix rebuild. One JSON line in, one banner out. No SDK.
- **a two-way street** — `trill ask "Push to origin?" --pill Allow --pill Deny`
  blocks and exits with the index of the pill you press. An agent's permission
  prompt becomes a banner, and the answer flows back down the same socket. No
  answer is never exit 0: silence isn't consent.
- **quiet by design** — the trill is the cat's, not the speaker's: there are
  no sound APIs anywhere in the binary. Flat surface, a few points of motion
  (none under Reduce Motion), hover to hold.
- **a stack, not a spreadsheet** — banners deal downward from the top-right
  as overlapping cards. A burst on one `--thread` stays one card with a
  count; hover it and the card opens into the list of what folded in — as
  many lines as the screen has room for, each one a button for its own
  event.
- **a question waits, and can answer itself** — an `ask` banner nobody
  catches parks as a slim fin on the right screen edge instead of vanishing,
  and stays there across restarts. It leaves when you answer it, when
  something else says it's answered (`trill resolve`, or a merged PR the
  GitHub bridge recognizes), or when a check *you declared in your rules
  file* finally says yes.
- **your next meeting, ten minutes out** — switch the Calendar source on and
  trill draws one quiet card before each meeting: the title, *in 10m*, a pill
  that opens the event, and a **Join** pill when the invite carries a link it
  recognizes. EventKit pushes, so a meeting moved on your phone moves the
  banner. trill reads your calendar; it never writes to it.
- **rules, not settings mazes** — `~/.config/trill/rules.json`: route a
  source to banner / inbox / digest / drop; quiet hours; critical punches
  through. A `digest` rule batches quietly and flushes on the hour as one
  card — "9 quiet things · ci ×4, garden ×3" — that opens the inbox on
  exactly those events. Hot-reloaded on save. The app's own switches are a file too
  (`config.json`, same directory) — the Settings window reads and writes that
  file and keeps nothing of its own, so anything you can click you can also
  type, and vice versa, without a restart.
- **the morning paper** — unlock a Mac that was busy without you and one
  low card says what it missed: *while you were away — 2 asks, 1 fault, 14
  notes*, with a click that opens the inbox on exactly those. Not a replay of
  the night's stack: nothing is re-drawn, the numbers are counted by kind so
  the asks lead, and a quiet night produces no card at all. It cannot
  interrupt you, because it only ever fires as you come back.
- **shy on a shared screen** — while macOS is showing its in-use indicator
  (something is capturing the screen, or the camera or mic is live) or a
  display is mirrored, every card drops its body and keeps only the title,
  exactly as if it had been sent `--redact`. Nothing to arm before a call; a
  small `eye.slash` on the card says why. One switch, on by default.
- **it knows you're in a Focus** — turn one on and trill stops competing
  with your own decision: chatter goes to the inbox, faults still land, and a
  question parks on the ledge as a fin so nobody is left blocked on an answer
  that never appeared. trill *reads* the Focus and never writes it — the
  toggle stays Apple's, and Settings deep-links you there. One switch, on by
  default; the per-kind detail is `focus` in rules.json.
- **resilient compositor** — panels are disposable; the queue is the truth.
  Unplug a display mid-burst and nothing is lost. A provider dying can't
  take rendering down; it re-probes and backs off on its own.
- **native and tiny** — one Swift `LSUIElement` binary that is both daemon
  and CLI. No Electron, no telemetry, no cloud, no login.

## the shape

```text
trill CLI     GitHub webhook    your calendar     usernoted db (experimental)
pounce/perch      │             │ EventKit push   │ read-only, schema-probed
    │  ▲          │             │                 │
 SocketProvider  GitHubWebhook  CalendarProvider  SystemMirrorProvider
    │  └── the answer to `trill ask`, written back when a pill is pressed
    └─────────────┴─────────────┴─────────────────┘
                  ▼
          EventRepository (actor: normalize · dedupe · persist · supervise)
                  ▼
          PolicyEngine (rules.json: banner / inbox / digest / drop · quiet hours)
                  ▼
          BannerQueue (coalescing · hover-pause/expand · capacity)
                  ▲
          DigestScheduler (tally per digest · one card on the hour)
                  ▲
          CatchUpReporter (what you missed · one card on unlock)
                  ▼
          BannerWindowSystem (NSPanel per card · stacked · all Spaces · over fullscreen)
```

## getting `trill`

The app **is** the CLI — one signed binary inside `Trill.app` serves both the
daemon and every verb — so all it takes is a symlink under a name a shell can
find. Whoever installs the bundle places it:

| install | who puts `trill` on PATH |
|---|---|
| Nix (`pkgs.trill`, this flake's overlay) | the package's own `bin/trill` |
| `scripts/dev-install.sh` (building from this checkout) | a link in a directory of yours already on PATH |
| the release ZIP, dragged to /Applications | **the app itself**, at first launch |

(A desktop that copies the bundle to a fixed path adds no fourth row. haus's
`haus.trill.enable` room places the bundle at `/Applications/Trill.app` — grants
are keyed per app path — and puts nothing on PATH itself: its own `trill`
wrapper resolves that path at call time, which is the right shape when whether
the bundle exists is a runtime fact.)

The last two pick the directory from your login shell's own `PATH` rather than
assuming one: `~/.local/bin` is the conventional answer and is on nobody's PATH
by default on macOS, so hardcoding it writes a file that exists and a command
that never runs. Nix-managed bins are skipped even when they *are* on PATH — a
link written there is gone at the next rebuild.

The app's own turn is deliberately timid: it places the link only when nothing
else already answers `trill`, never replaces a real file sitting on the name,
and never claims the name from a Debug build. Switch it off with
`"cliLink": false` in `~/.config/trill/config.json`, or in Settings ▸ General —
which also tells you what `trill` resolves to right now, and says so plainly
when the link is placed but its directory is on no PATH.

## quick taste

```sh
trill send --title "Landing page shipped" \
           --body "Preview promoted to production" \
           --source deploy --symbol checkmark.circle --thread deploys

echo '{"title":"Backup complete","body":"3.8 GB copied","source":"backups","urgency":"low"}' \
  | trill send --json

trill ping   # is the daemon up?

trill send --title "review me" --kind ask --key pr-142 \
           --until pr-merged:142,hausfold/trill   # clears itself when it merges
trill resolve pr-142    # …or say so yourself, from anywhere, any time later

# and the one that answers back: blocks until a pill is pressed, exits with
# its index (0 = the first --pill). 75 means nobody answered — never consent.
trill ask "Push to origin?" --pill Allow --pill Deny --timeout 300 \
  && git push

trill doctor            # which listed apps does macOS still notify for itself?
trill doctor --all      # …check every app on the Mac, not just the listed ones
trill doctor --notify   # …and put the findings on screen, click to be walked through
```

```jsonc
// ~/.config/trill/rules.json
{
  "rules": [
    { "match": { "source": "slack", "titleContains": "mentioned" }, "delivery": "banner" },
    { "match": { "source": "slack" }, "delivery": "digest", "digest": "work" },
    { "match": { "source": "ads" }, "delivery": "drop" },

    // …and *where* it draws: chats on the laptop panel, faults on whichever
    // display you're facing. `primary` (the menu-bar one) is the default;
    // `builtin` and `external` are the hardware. A rule that names only a
    // display still banners — every target falls back to `primary`, so
    // unplugging a monitor moves its banners rather than losing them.
    { "match": { "kind": "chat" }, "display": "builtin" },
    { "match": { "kind": "fault" }, "display": "active" }
  ],
  "quietHours": { "startMinute": 1320, "endMinute": 420 },

  // What a *Focus* means, per kind. trill reads the Focus macOS is in — it
  // never turns one on or off. This block is the shipped default, so a file
  // that never mentions it behaves exactly like this: chatter stops
  // interrupting, faults still land, and a question parks on the ledge as a
  // fin instead of being swallowed (somebody is blocked on the answer).
  // Name one kind and the rest keep their defaults. `critical` punches
  // through regardless, the way it does through quiet hours — and quiet
  // hours have the last word over all of it.
  // The switch for whether trill looks at Focus at all is `focusAware` in
  // config.json, beside shyness.
  "focus": { "default": "inbox", "fault": "banner", "ask": "ledge" },

  // What `--until NAME` may name. The command lives here, in your file —
  // never on the wire, because anything local can talk to trill's socket.
  // argv, not a command line: there is no shell in this path.
  "resolvers": {
    "pr-merged": {
      "run": ["gh", "pr", "view", "$1", "--repo", "$2", "--json", "state", "-q", ".state"],
      "resolveWhen": { "stdout": "MERGED" },
      "every": "2m", "timeout": "10s", "giveUpAfter": "12h"
    },
    "endpoint-up": { "get": "https://$1/healthz", "resolveWhen": { "status": 200 } }
  }
}
```

## what about other apps' notifications?

Three lanes, in order of honesty:

1. **First-party** (shipping): anything local speaks the socket. haus
   apps, scripts, CI — clean, supported, forever.
2. **System Mirror** (experimental, off by default): reads the `usernoted`
   store read-only under Full Disk Access and redraws other apps' banners,
   as `com.apple.MobileSMS` and friends — the bundle id is the rule's
   `source`. Undocumented surface — a schema probe disables it safely when
   macOS moves. trill stays fully useful without it.
   **A mirrored card arrives about five seconds after the notification
   itself**: usernoted batches its writes, nothing outside that daemon can
   hurry it, and the number is here rather than hidden because it decides
   what the mirror is good for. Its *timestamp* is exact, so a late card
   still says when the thing happened.
3. **Suppressing Apple's own banners** is Focus + per-app settings — trill
   deep-links you there but never pretends to own that dial. It *reads* the
   Focus you're in (see `focus` in rules.json above) and routes accordingly;
   turning one on or off stays a click of yours, in Apple's pane or in
   whatever drives it on your desktop.

### `trill doctor` — the duplicate-banner check

Mirroring an app macOS is *also* drawing means seeing everything twice, so
trill can at least tell you which apps those are. `trill doctor` reads Apple's
own per-app notification preferences (read-only, and undocumented — see
`NotificationSettingsAudit`) and reports every listed app that still has
**Desktop** ticked or **Play sound** on. Exit code 4 means it found some, so a
rebuild hook can gate on it.

Those preferences live in an Apple group container, which is TCC-protected —
so **`doctor` needs Full Disk Access**, the same grant System Mirror wants.
Without it there is no answer to give, and trill gives that one: `can't
tell`, exit code **5**. A check that quietly exited 0 while blind would make
every un-granted Mac look clean.

"Listed" means the bundle-id-shaped `source` values in your `rules.json`;
`--all` widens it to every app on the Mac, and naming bundle ids explicitly
narrows it.

`--notify` puts the findings on screen as banners with one action —
**Silence Native Banners**. Clicking one opens System Settings and floats a
helper panel beside it: the app's row as macOS draws it (Apple dropped per-app
anchors from that deep link, so it always lands at the top of the pane and
finding the row is the real work), one sentence naming what's left to change,
and a replica that animates the clicks — untick **Desktop**, turn **Play
sound for notification** off.

**Done** moves to the next app. trill asks rather than watches because it
can't rely on watching: the store needs Full Disk Access, and on a Mac that
hasn't granted it there is nothing to observe. Where trill *can* read, the
panel ticks apps off by itself as macOS agrees — the row's subtitle shortens,
the sentence narrows to what's left, and the replica drops the step you've
already done.

The helper only ever walks the apps the audit that opened it named — the
banner carries them with it, so a summary banner standing for four listed
apps still walks those four and not the sixty-odd others macOS holds
preferences for. trill asks you to silence what you told it to redraw; it
does not ask you to switch macOS's notifications off wholesale. Widening
that is `--all`, and it takes typing `--all`.

Note that the pane changed shape in macOS 26 (Tahoe): the old
None/Banners/Alerts radio is now a **Desktop** checkbox plus a
Temporary/Persistent choice that only applies while Desktop is ticked.
Notification Center and Lock Screen stay ticked — trill redraws the banner,
it doesn't replace the notification. Same panel shape as the Full Disk
Access assistant, and the same promise: **trill opens the pane, it never
writes the setting.** There's no API to change another app's notification
preferences, and silently rewriting a pane the user believes only they control
isn't a trade this app makes.

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the invariants and
[PRD.md](./PRD.md) for the milestones.

## status

Pre-release scaffold. The first-party pipeline (socket → rules → banners →
inbox) is the v1 target. System Mirror's feasibility spike is done (macOS
26.5, 2026-08-25) and it ships opt-in and experimental — see
[ARCHITECTURE.md](./ARCHITECTURE.md), "The undocumented mirror", for the
measurements it stands on.

MIT. Part of the [hausfold](https://github.com/hausfold) family.
