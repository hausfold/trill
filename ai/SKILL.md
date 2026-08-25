---
name: trill
description: Put a notification banner on this Mac's screen from the command line, and check which apps are still notifying twice. Use when the user says "tell me when this finishes", "notify me when the build is done", "ping me when it lands", "send me a notification", "let me know when you're done", or asks why they're seeing double banners. Also the right tool when a long-running command should announce itself instead of the user watching a terminal.
---

# Trill — the quiet notification compositor

Trill draws its own notification banners on macOS. Not Apple's Notification
Center: its own daemon, its own rules file, and never a sound. Anything that
can run a command can put a banner on screen — which is what makes it the
right answer to *"tell me when this is done"*.

You reach it with the `trill` command; the daemon must be running (`trill ping`
exits 0 silently when it is, everything else exits **2**). Banners never steal
focus, so sending one is safe mid-work. No sound, ever — don't promise one.

## Verbs

| do this | run this |
|---|---|
| put a banner on screen | `trill send --title "Deploy landed"` |
| …with detail | `trill send --title "Build failed" --body "3 tests red" --urgency critical` |
| …clickable | `trill send --title "PR open" --url https://github.com/…` |
| …with up to 3 buttons | `trill send --title "PR open" --action "Open PR=https://…" --action "Diff=https://…"` |
| …saying what it asks of the user | `trill send --title "Lane blocked" --kind ask` |
| …that clears itself when a check passes | `trill send --title "…" --kind ask --until pr-merged:142,org/repo` |
| that question got answered | `trill resolve <id-or-key>` |
| send a fully-formed event | `echo '{"title":"Backup complete"}' \| trill send --json` |
| is the daemon up? | `trill ping` |
| which apps still banner themselves? | `trill doctor` (`--all --json` for every app) |
| open the inbox window | `trill inbox` |
| …just the asks | `trill inbox --asks` |
| everything, exhaustively | `trill help` |

`--kind` colors the banner by what it asks of the user: `ask` (blocked on
them), `fault` (broke), `chat` (a human), `pulse` (in flight), `done`
(finished well), `note` (fyi, the default). An `ask` whose banner times out
unattended doesn't vanish — it parks as a slim fin on the right screen edge,
across restarts, until answered or dismissed. So `--kind ask` is the shape for
"I'm blocked, come back to me": it waits; nothing else does.

An ask can also stop waiting on its own. `trill resolve <id>` (the id `send`
printed) clears it from any process, any time later. `--until NAME[:args]` has
the daemon poll a check *the user declared* in their rules file (an undeclared
name does nothing). `--key K` names the ask yourself, and re-sending with that
key replaces its fin.

`--urgency` (`low`/`normal`/`critical`) is the loudness, a different axis: a
fault can be low, a note critical. `--thread` groups related banners.
`--source <slug>` is what the rules file matches on; `--redact` keeps body and
subtitle off the banner. `--action "Label=https://…"` — also `Label=app:ID` or
`Label=lane:repo/name` for that holt lane's window, repeatable — adds buttons;
the first is also what clicking the banner body does.

## Exit codes — check these, they mean different recoveries

| | meaning | what to do |
|---|---|---|
| 0 | **accepted** by the daemon — not necessarily drawn | see below |
| 1 | bad usage | fix the flags; `--title` is required unless `--json` |
| 2 | daemon unreachable | Trill isn't running — tell the user to launch it |
| 3 | daemon refused the *request* — malformed JSON, empty title, unknown verb | fix the call, not the rules |
| 4 | `doctor`: apps found still notifying natively | report the list |
| 5 | `doctor`: can't read macOS's settings | needs Full Disk Access — **not** "all quiet" |

**Exit 0 means the daemon took the event, not that a banner appeared.** The
rules run afterwards: a `drop` rule, coalescing or quiet hours can route it to
the inbox instead, and a `digest` rule holds it for the hourly card — none of
them change the exit code. Say "sent", not "you'll see it on screen".

**Exit 5 means *can't tell*, not "nothing to fix".** Three verdicts, not two;
reporting the third as clean is a bug this app already shipped once.

## When to reach for this

- "tell me when this finishes" → run it, then `trill send`
- "notify me if the deploy fails" → `--urgency critical` in that branch
- "come back to me when you're blocked" → `--kind ask`; it parks and waits
- "why two banners for Slack?" → `trill doctor`; trill only *reports*, the
  clicking is theirs

## When NOT to

- **A sound or an alarm.** Trill has no audio, deliberately. Reach for
  `afplay` or `osascript`, and say why.
- **A reminder at a time.** Trill fires when told to; it has no scheduler. Use
  `at`, cron or a Calendar event, and have that call `trill send`.
- **Silencing another app.** Trill reads Apple's settings and never writes
  them. `trill doctor` names the apps; the clicking is the user's.
- **Changing which notifications get through.** That's their
  `~/.config/trill/rules.json`, edited as a file — not a CLI flag.
- **A file needs to go somewhere the user can grab it.** That's `perch add`.

## Rules file — `~/.config/trill/rules.json`

Read and edit it as a file. First matching rule wins; no match means banner.

```json
{
  "rules": [
    { "match": { "source": "ads" }, "delivery": "drop" },
    { "match": { "source": "slack" }, "delivery": "digest", "digest": "work" },
    { "match": { "titleContains": "backup" }, "delivery": "inbox" }
  ],
  "quietHours": { "startMinute": 1320, "endMinute": 420 },
  "resolvers": {
    "pr-merged": { "run": ["gh", "pr", "view", "$1", "--repo", "$2", "--json", "state", "-q", ".state"],
                   "resolveWhen": { "stdout": "MERGED" }, "every": "2m", "giveUpAfter": "12h" }
  }
}
```

`resolvers` is what `--until` may name — argv (or `"get": "https://…"`) with
`$1`…`$9` filled from the invocation's comma-separated args. It is the only
place a command may live (**you cannot pass one on the command line**), so
adding one means editing this file, which is the user's call.

`match` takes `source` (exact, case-insensitive), `titleContains` and
`urgencyAtMost`. `delivery` is `banner`, `inbox`, `digest` (with a sibling
`digest` name) or `drop`, written **flat beside** `match`, not nested in it. A
`digest` rule banners nothing then: it tallies and draws one card on the hour
("9 quiet things · ci ×4, garden ×3") that opens the inbox on exactly those.
`quietHours` is minutes since local midnight and may cross it (`1320`/`420` is
22:00–07:00); inside it non-critical events are demoted, digest cards held.

## Settings file — `~/.config/trill/config.json`

The app's own switches, and the source of truth for them: Settings reads and
writes this same file, and trill re-reads it live. All four keys, at their
defaults — `{"launchAtLogin": true, "persistHistory": true, "systemMirror":
false, "githubBridge": false}`; each is optional. `persistHistory` off stops
disk writes from that moment on. Don't write the file if it's a symlink into
`/nix/store`: the desktop generates it there and a rebuild reverts you.

## Traps

- **Everything but `trill help` needs the daemon.** Exit 2 isn't your command
  failing, it means nothing is listening. Don't retry it in a loop.
- **A dropped event is indistinguishable from a delivered one.** Both exit 0;
  no code says "a rule ate it". When the user says "I never got it", read
  `~/.config/trill/rules.json` — that is the only place the answer lives.
- **Quiet hours silently demote** every non-critical event to inbox-only.
  `--urgency critical` is the way through; a rule can still `drop` it.
- **`--redact` is for a shared screen, not for secrets** — it keeps body and
  subtitle off the banner, not out of the inbox. Never put a secret in any
  field: banners are drawn on screen and recorded to the inbox database.
- **`--until` is a promise about the user's config, not yours.** It names a
  resolver in *their* `rules.json`; an undeclared name is logged and the fin
  simply stays. Read the file before you promise a banner will clear itself.
- **`trill doctor` exits 5 when it can't read** — "unknown", never "clean".
