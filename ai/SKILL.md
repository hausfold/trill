---
name: trill
description: Put a notification banner on this Mac's screen from the command line, ask the user a question on screen and wait for their answer, read back what trill already fired, and check which apps are still notifying twice. Use when the user says "tell me when this finishes", "notify me when the build is done", "ping me when it lands", "let me know when you're done", "ask me before you do that", "check with me first", "don't do it without asking", "what did you send me?", "what did I miss while I was away?", "what notifications have I had?", asks "how far along is it?" or wants a long build to show its progress on screen, or asks why they're seeing double banners. Also the right tool when a long-running command should announce itself, or when you need a yes/no from someone who isn't watching the terminal.
---

# Trill — the quiet notification compositor

Trill draws its own notification banners on macOS — its own daemon, its own rules file, its own
history. Anything that runs a command can put one on screen (the right answer to *"tell me when this
is done"*), `trill ask` can put a *question* there and wait, and `trill history` reads back what
already fired. The daemon must be running (`trill ping` exits 0 silently, everything else **2**),
banners never steal focus, and **there is no sound, ever** — don't promise one.

## Verbs

| do this | run this |
|---|---|
| put a banner on screen | `trill send --title "Deploy landed"` |
| …with detail | `trill send --title "Build failed" --body "3 red" --urgency critical` |
| …that waits for the user, and clears itself | `trill send --title "…" --kind ask --until pr-merged:142,org/repo` |
| **ask the user, and wait for the answer** | `trill ask "Push to origin?" --pill Allow --pill Deny` |
| that question got answered | `trill resolve <id-or-key>` |
| a long job, one card that fills up | `trill send --key build --progress 42% --title "haus rebuild"` |
| send a fully-formed event | `echo '{"title":"Backup complete"}' \| trill send --json` |
| **what fired? read it back** | `trill history --since 2h [--unread] [--json]` |
| which apps still banner themselves? | `trill doctor` (`--all --json` for every app) |
| open the inbox window | `trill inbox [--asks]` · everything: `trill help` |
| teach an agent trill | `trill skill` · `trill skill install` writes it into every client |
| **trill itself is broken — file it** | `trill report` · `--print` for the block and URL without a browser |

`--kind` colors the banner by what it asks of the user: `ask` (blocked on them), `fault` (broke),
`chat` (a human), `pulse` (in flight), `done` (finished well), `note` (fyi, the default). An `ask`
nobody catches parks as a slim fin on the screen edge, across restarts, and can stop waiting on its
own — `trill resolve <id>` (the id `send` printed) from any process, or `--until NAME[:args]`, a
check *the user declared* in their rules. `--key K` names it; re-sending replaces its fin.

`--progress 0.42|42%` draws a bar and **requires `--key`**: later sends under that key **replace**
that card instead of stacking a second — one card per build, `--kind` defaulting to `pulse`. It gets
its seconds on screen then keeps filling as a fin, so **send the ending under the same key** (`--kind
done`/`fault`) — that takes the fin down. Ticks are live, not history; a bare `42` is refused.

`--urgency` (`low`/`normal`/`critical`) is loudness, a different axis: a fault can be low, a note
critical. `--thread` groups banners, `--source <slug>` is what rules match on, `--redact` keeps body
and subtitle off it, and `--action "Label=https://…"` (or `Label=app:ID`, or `Label=lane:repo/name`
for a scruff lane; repeatable) adds up to 3 buttons — the first is what clicking the card does.

`history` is the read half of `send` and the only listing anything can parse — `inbox` opens a
*window*. Newest first, from the rows that window draws, last 1000, narrowed by
`--source`/`--kind`/`--search`/`--limit`; `--json` gives `{"event": …, "decision": …, "readAt": …}`
a row, `event` being what `send --json` takes. **Unread = trill never showed them this** (a rule,
quiet hours, a locked screen) — not "unopened".

## Exit codes — check these, they mean different recoveries

| | meaning | what to do |
|---|---|---|
| 0 | **accepted** by the daemon — not necessarily drawn | see below |
| 1 | bad usage | fix the flags; `--title` is required unless `--json` |
| 2 | daemon unreachable | Trill isn't running — tell the user to launch it |
| 3 | refused: bad JSON, empty title, a verb this daemon doesn't know, `skill install` leaving a file that differs alone (a symlink haus manages is not that: exit 0) | fix the call, or update Trill |
| 4 | `doctor`: apps found still notifying natively | report the list |
| 5 | **can't tell**: `doctor` can't read macOS's settings, or `history` is switched off | needs Full Disk Access · **not** "all quiet" and **not** "nothing fired" |

**Exit 0 means the daemon took the event, not that a banner appeared** — a rule, coalescing, quiet
hours, a digest or **a Focus** can route it elsewhere, so say "sent", not "you'll see it" (and
`trill history` is how to find out which). In a Focus, chat and note go to the inbox, a fault still
banners, an `ask` parks on the ledge and still blocks. **Exit 5 is *can't tell***: three verdicts,
and calling the third one clean has already shipped here as a bug.

## `trill ask` — the two-way one

Everything above is one-way. `trill ask` **blocks** until a pill is pressed and **exits with that
pill's index** (0 = the first `--pill`) — your permission prompt, as a banner:

    trill ask "Push to origin?" --pill Allow --pill Deny --timeout 300 && git push

No `--pill` means Yes and No; three at most, the pressed label goes to stdout, and **give it a
`--timeout` unless the user is sitting there**. Its codes are its own, because the low ones are
answers: **0…2** the pill pressed · **64** bad usage · **69** no daemon · **70** refused · **75**
nobody answered — timed out, taken down, resolved elsewhere, kept off screen. **75 is never consent.**

## When to reach for this

- "tell me when this finishes" → `trill send` after it; "how far along?" → `--key` + `--progress`
- "notify me if the deploy fails" → `--urgency critical`; "come back when blocked" → `--kind ask`
- "ask me before you push / deploy" → `trill ask`; act on its exit code
- "what did I miss?" → `trill history --since 8h --unread`; "what did you send?" → `trill history`
- "why two banners for Slack?" → `trill doctor`; trill only *reports*

## When NOT to

- **A sound, an alarm, or a reminder at a time.** No audio and no scheduler, deliberately: reach for
  `afplay`, and for `at`/cron/Calendar calling `send`.
- **Silencing another app, or turning a Focus on.** Trill *reads* Apple's settings and the Focus and
  never writes either: `doctor` names the apps, the clicking is theirs.
- **Changing what gets through** — that's their `rules.json`, a file. **A file to grab** is `perch`.

## Rules file — `~/.config/trill/rules.json`

Read and edit it as a file. First matching rule wins; no match means banner.

```json
{
  "rules": [
    { "match": { "source": "ads" }, "delivery": "drop" },
    { "match": { "source": "slack" }, "delivery": "digest", "digest": "work" }
  ],
  "quietHours": { "startMinute": 1320, "endMinute": 420 },
  "focus": { "default": "inbox", "fault": "banner", "ask": "ledge" },
  "resolvers": { "pr-merged": { "every": "2m", "giveUpAfter": "12h",
    "run": ["gh", "pr", "view", "$1", "-R", "$2", "--json", "state", "-q", ".state"],
    "resolveWhen": { "stdout": "MERGED" } } }
}
```

`resolvers` is what `--until` may name — argv (or `"get": "https://…"`) with `$1`…`$9` filled from
the invocation's args, and the only place a command may live (**never the wire**), so it's theirs.

`match` takes `source` (exact, case-insensitive — a sender's slug, or a bundle id like
`com.apple.MobileSMS` for anything System Mirror redrew, ~5 s late because macOS batches its store
writes), `titleContains`, `urgencyAtMost` and `kind`. `delivery` — `banner`, `inbox`, `digest`
(with a sibling `digest` name) or `drop` — goes **flat beside** `match`, never nested in it. A
`digest` rule banners nothing: it tallies, drawing one card on the hour ("9 quiet things · ci ×4")
that opens the inbox on exactly those. `display` names the screen (`primary`, the menu-bar one and
the default · `active` · `builtin` · `external`); an unplugged one falls back rather than swallowing.
`quietHours` is minutes since local midnight and may cross it, demoting non-critical events inside
it; `focus` does the same per kind in a Focus, naming one kind leaving the rest at the example's.

## Settings file — `~/.config/trill/config.json`

The app's own switches, and the truth for them — Settings reads and writes this same file, live. Every key at its default,
each optional: `{"launchAtLogin": true, "persistHistory": true, "systemMirror": false, "githubBridge": false,
"shyWhenWatched": true, "catchUpCard": true, "focusAware": true, "calendar": false, "calendarLeadMinutes": 10, "cliLink":
true, "fontFamily": ""}` — and `persistHistory: false` is what makes `history` exit 5. `systemMirrorApps` has no default:
absent mirrors every app, a list exactly those, `[]` none. Don't write the file if it symlinks into `/nix/store`.

## Traps

- **Every verb but `help` and `skill` needs the daemon.** Exit 2 (69 for `ask`) means nothing is
  listening, not that your command was wrong. Don't loop on it.
- **`trill: command not found` is not "trill isn't installed".** The shim only lands in a directory
  already on the login PATH; the app is always its own CLI, so
  `/Applications/Trill.app/Contents/MacOS/Trill` (or `~/Applications/…`) takes every verb here.
- **A dropped event looks exactly like a delivered one** — both exit 0. On "I never got it", read
  `~/.config/trill/rules.json`; the answer is only there.
- **Quiet hours silently demote** non-critical events (an `ask` there exits 75) and a Focus reroutes
  them — `--urgency critical` is the way through both. `history` is how you see what that did.
- **`--redact` keeps body/subtitle off the *banner*, not the inbox or `history`** — and trill
  redacts by itself while the screen is watched. Never put a secret in any field.
- **`trill ask` blocks your shell**; 75 means nobody answered, not yes.
