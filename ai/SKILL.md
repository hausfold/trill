---
name: trill
description: Put a notification banner on this Mac's screen from the command line, and check which apps are still notifying twice. Use when the user says "tell me when this finishes", "notify me when the build is done", "ping me when it lands", "send me a notification", "let me know when you're done", or asks why they're seeing double banners. Also the right tool when a long-running command should announce itself instead of the user watching a terminal.
---

# Trill — the quiet notification compositor

Trill draws its own notification banners on macOS. It is not Apple's
Notification Center: it has its own daemon, its own rules file, and it never
makes a sound. Anything that can run a command can put a banner on screen —
which is what makes it the right answer to *"tell me when this is done"*.

You reach it with the `trill` command. The daemon must be running; `trill ping`
exits 0 when it is (printing nothing), and `send`/`doctor` exit **2** when it
isn't.

Banners never steal focus, so sending one is safe in the middle of the user's
work. There is no sound, ever — don't promise one.

## Verbs

| do this | run this |
|---|---|
| put a banner on screen | `trill send --title "Deploy landed"` |
| …with detail | `trill send --title "Build failed" --body "3 tests red" --urgency critical` |
| …clickable | `trill send --title "PR open" --url https://github.com/…` |
| …attributed to something | `trill send --title "…" --source deploy --symbol checkmark.circle` |
| …hiding the detail on a shared screen | `trill send --title "…" --body "…" --redact` |
| announce a long command when it ends | `make build; trill send --title "build done"` |
| send a fully-formed event | `echo '{"title":"Backup complete"}' \| trill send --json` |
| is the daemon up? | `trill ping` |
| which apps still banner themselves? | `trill doctor` |
| …every app, as JSON | `trill doctor --all --json` |
| everything, exhaustively | `trill help` |

`--urgency` is `low`, `normal` (default) or `critical`. `--thread <name>`
groups related banners. `--source <slug>` is what the user's rules file matches
on — give a long-running job its own source so they can route it later.

## Exit codes — check these, they mean different recoveries

| | meaning | what to do |
|---|---|---|
| 0 | **accepted** by the daemon — not necessarily drawn | see below |
| 1 | bad usage | fix the flags; `--title` is required unless `--json` |
| 2 | daemon unreachable | Trill isn't running — tell the user to launch it |
| 3 | daemon refused the *request* — malformed JSON, empty title, unknown verb | fix the call, not the rules |
| 4 | `doctor`: apps found still notifying natively | report the list |
| 5 | `doctor`: can't read macOS's settings | needs Full Disk Access — **not** "all quiet" |

Two of these lie in the same direction, and both matter:

**Exit 0 means the daemon took the event, not that a banner appeared.** The
rules run afterwards, asynchronously. A `drop` rule, a `digest` rule, thread
coalescing, or quiet hours can all route it to the inbox instead — and none of
them change the exit code. Say "sent" and not "you'll see it on screen".

**Exit 5 means *can't tell*, not "nothing to fix".** There are three verdicts
here, not two, and reporting the third as clean is the bug this app already
shipped once.

`trill ping` on a healthy daemon prints **nothing** and exits 0. The silence is
the answer; the one-line message only exists on failure.

## When to reach for this

- "tell me when this finishes" → run the thing, then `trill send`
- "notify me if the deploy fails" → `trill send --urgency critical` in the
  failure branch
- "why am I getting two banners for Slack?" → `trill doctor`, then read out the
  list. Trill only *reports*; the user turns Apple's off themselves.
- "let me know without stealing my screen" → that's the default; say so.

## When NOT to

- **The user wants a sound or an alarm.** Trill has no audio, deliberately.
  Reach for `afplay` or `osascript` instead, and say why.
- **The user wants a reminder at a time.** Trill fires when told to; it has no
  scheduler. Use `at`, a cron job or a Calendar event, then have it call
  `trill send`.
- **The user wants to silence another app's notifications.** Trill reads Apple's
  settings and never writes them. `trill doctor` names the apps; the clicking is
  the user's.
- **The user wants to change which notifications get through.** That's their
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
  "quietHours": { "startMinute": 1320, "endMinute": 420 }
}
```

`match` takes `source` (exact, case-insensitive), `titleContains` (substring,
case-insensitive) and `urgencyAtMost`. `delivery` is `banner`, `inbox`,
`digest` (with a sibling `digest` name) or `drop`, written **flat beside**
`match`, not nested inside it. `quietHours` is minutes since local midnight and
may cross midnight — `1320`/`420` is 22:00–07:00 — and inside that window every
non-critical event is demoted to inbox-only whatever the rules said.

## Traps

- **`trill send` and `trill doctor` need the daemon; `trill help` doesn't.**
  Exit 2 is not a failure of your command, it means nothing is listening. Don't
  retry it in a loop.
- **A dropped event is genuinely indistinguishable from a delivered one.** Both
  exit 0. There is no code that says "a rule ate it". So when the user says "I
  never got it", read `~/.config/trill/rules.json` before you suspect anything
  else — that is the only place the answer lives.
- **Quiet hours silently demote.** Inside the window every non-critical event
  becomes inbox-only. `--urgency critical` is the documented way through; a rule
  can still `drop` it, but silence alone can't.
- **`--redact` hides the body *and subtitle* from the banner, not from the
  inbox.** It is for a shared screen, not for secrets.
- **Never put a secret in `--title` or `--body`.** Banners are drawn on screen
  and recorded to the inbox database.
- **`trill doctor` needs Full Disk Access** and says so by exiting 5. Treat that
  as "unknown", never as "clean".
