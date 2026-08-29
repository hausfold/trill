<div align="center">

# 🔔 trill

**no noise, just a trill**

a quiet, scriptable notification compositor for macOS — small silent cards, drawn by a daemon you own, from anything that can run a command

</div>

---

Your build finishes in a window you can't see. Your agent stops, blocked on a
yes it has no way to ask for. Slack pings you five times about one thread.
macOS has the same answer for all three: the same banner, with a chime.

trill is the other answer. A cat doesn't meow at everything — a trill is the
small chirred note it makes in passing, enough to register that something
happened, not enough to stop anyone's afternoon. So: flat, silent cards, one
visual language for every tool on the Mac, and a command line that puts one on
screen in six words.

It isn't a Notification Center replacement — Apple doesn't sell that
entitlement. It's the honest version: a pipeline trill owns end to end, fed by
sources you turn on one at a time.

```sh
trill send --title "Deploy landed" --body "preview promoted to production" \
           --source deploy --kind done

# the two-way one: blocks until a pill is pressed, exits with its index
trill ask "Push to origin?" --pill Allow --pill Deny --timeout 300 && git push

# one card for a whole build, not fifty banners
trill send --key haus --progress 42% --title "haus rebuild" --body "12 of 30"

trill ping     # is the daemon up?
trill report   # something's wrong — file it, with this Mac's details filled in
```

[Grab the latest release](https://github.com/hausfold/trill/releases/latest),
drag `Trill.app` to `/Applications`, launch it once. macOS 14+, Developer-ID
signed and notarized, no Dock icon, no account. On
[haus](https://github.com/hausfold/haus) it's
`haus.notifications.compositor = true;`. → [installing trill](docs/install.md)

## what it does

- **anything can draw one** — a line of shell, or a JSON line down the socket.
  No SDK, no key. `--kind` colors the card by what it asks of you (`ask` ·
  `fault` · `chat` · `pulse` · `done` · `note`); `--urgency` is the separate
  axis of loudness, so a fault can be low and a note critical.
- **a question waits, and can answer itself** — an `ask` nobody catches parks
  as a slim fin on the screen edge instead of vanishing, and stays there across
  restarts. It leaves when you answer it, when something else says it's
  answered (`trill resolve`, or a merged PR), or when a check *you declared in
  your rules file* finally says yes. Exit code = the pill pressed, **75 =
  nobody answered, which is never consent.**
- **a long build gets one card, then the edge** — `--key` plus `--progress` is
  one bar that fills instead of fifty banners. When its seconds on screen are
  up it parks beside the questions and keeps filling, so a twenty-minute
  rebuild is still glanceable at minute twelve. The ending takes it down and
  gets a card of its own.
- **a burst stays one card** — cards deal downward from the top-right and
  overlap; everything on one `--thread` folds into a single card with a count.
  Hover to hold it, hover to open it into the list of what folded in, each line
  a button for its own event.
- **it reads the room** — quiet hours, and the Focus you already turned on:
  chatter goes to the inbox, faults still land, and a question parks on the
  ledge rather than being swallowed while somebody waits on the answer. trill
  *reads* the Focus and never writes it; the dial stays Apple's.
- **shy on a shared screen** — while macOS is showing its in-use indicator
  (screen capture, camera or mic) or a display is mirrored, every card drops its
  body and keeps only the title, exactly as if it had been sent `--redact`.
  Nothing to arm before a call.
- **the morning paper** — unlock a Mac that was busy without you and one low
  card says what it missed: *while you were away — 2 asks, 1 fault, 14 notes*,
  and clicks through to exactly those. Not a replay: a quiet night draws
  nothing, and it can only ever fire as you sit back down.
- **your next meeting, ten minutes out** — turn the Calendar source on and each
  meeting gets one quiet card: the title, *in 10m*, and a **Join** pill when the
  invite carries a link trill recognizes (the first `https://` in someone's
  notes is as often a doc, and a pill that opens one is a lie in a button).
  EventKit pushes, so a meeting moved on your phone moves the card. trill reads
  your calendar and holds no access to write to it.
- **the overflow has somewhere to go** — digest cards, evicted fins, anything
  quiet hours held back: it's all in the inbox, live and searchable. Unread
  means trill never actually put it in front of you — including the banners it
  drew at a locked screen.
- **other apps, if you want them** — System Mirror redraws other apps' banners
  in trill's language, off by default and quarantined behind a schema probe,
  and `trill doctor` names the ones macOS is now drawing twice.
- **silent, by construction** — there is no audio call anywhere in this binary,
  not even for critical. Flat surfaces, a few points of motion, none of it under
  Reduce Motion. Nothing ever steals focus.
- **native and small** — one Swift `LSUIElement` binary that is both the daemon
  and the CLI. No Electron, no telemetry, no cloud, no login.

Everything trill decides comes out of two hot-reloaded JSON files in
`~/.config/trill/`, and Settings is a view onto them: anything you can click you
can type. → [rules and settings](docs/rules.md)

## more

- [Install](docs/install.md) — the release, Nix, haus, and what puts `trill` on your PATH
- [Rules & settings](docs/rules.md) — `rules.json`, `config.json`, resolvers, displays
- [Other apps](docs/other-apps.md) — System Mirror, `trill doctor`, and the silence walkthrough
- [`ai/SKILL.md`](ai/SKILL.md) — the agent surface: drop it in and *"tell me when this finishes"* works first try
- [Architecture](ARCHITECTURE.md) — the invariants, and the measurements they stand on
- [`AGENTS.md`](AGENTS.md) — building it, testing it, shipping it
- `trill help` — every verb, every flag

---

<div align="center">

<sub>**pre-release** · every path that could lose your work is either reversible by design or stops to ask you first — that's the intent, not a warranty. run it on a machine you can afford to rebuild, and [tell us what breaks](https://github.com/hausfold/trill/issues).</sub>

<sub>MIT · one of the [hausfold](https://github.com/hausfold) repos — [haus](https://github.com/hausfold/haus) rebuilds the Mac, this is how it tells you something happened</sub>

<a href="https://hausfold.co">⌂ hausfold</a>

</div>
