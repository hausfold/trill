# Other apps' notifications

Three lanes, in order of honesty.

## 1. First-party — anything that can run a command

The socket is the supported road, forever: one JSON line in, one banner out.
Scripts, CI, hooks, agents and the rest of the
[hausfold](https://github.com/hausfold) family speak it directly. See
[the rules file](rules.md).

## 2. System Mirror — experimental, off by default

Reads Apple's `usernoted` store **read-only** under Full Disk Access and
redraws other apps' banners in trill's language. The bundle id is what rules
match on, so `com.apple.MobileSMS` is Messages. Turn it on in **Settings ▸
Sources**.

It's an undocumented surface, so it's quarantined: the schema — tables *and*
columns — is probed before every session, and any drift disables the source with
a visible reason rather than breaking the pipeline. trill stays fully useful
without it.

**A mirrored card arrives about five seconds after the notification itself.**
usernoted batches its writes and nothing outside that daemon can hurry it, which
is what decides whether the mirror is any use to you. The card's *timestamp* is
exact, so a late card still says when the thing happened.

**Which apps it draws is yours to pick.** Settings' **Apps** pane lists every app
System Settings itself lists, one tick each, and writes the ticked ones to
[`systemMirrorApps`](rules.md#configjson--the-apps-own-switches). Ticking an app
later starts it from the present rather than replaying what it missed.

## 3. Silencing Apple's own banners — yours to click

If macOS is *also* drawing an app trill mirrors, you see everything twice. trill
names those apps and walks you to the switch, but won't throw it: **trill reads
Apple's notification settings and never writes them.** There is no API for it,
and silently rewriting a pane you believe only you control isn't a trade this
app makes.

### `trill doctor` — the duplicate-banner check

```sh
trill doctor            # the apps your rules.json names
trill doctor --all      # every app on the Mac
trill doctor --notify   # …and put the findings on screen, click to be walked through
trill doctor --json     # for a hook
```

It reads Apple's per-app preferences read-only and reports every app that still
has **Desktop** ticked or **Play sound** on. **Exit 4** means it found some, so a
rebuild hook can gate on it. The default set is the bundle-id-shaped `source`
values in your `rules.json`; naming bundle ids narrows it further.

### Exit 5 is a real answer: *can't tell*

Those preferences live in a TCC-protected Apple group container, so **`doctor`
needs Full Disk Access**, the same grant System Mirror wants. Without it there is
no answer to give, and trill gives that one: `can't tell`, **exit code 5**. A
check that exited 0 while blind would make every un-granted Mac look clean.

### The walkthrough

`--notify`'s one action — **Silence Native Banners** — and the **Silence…**
button beside each app on the Apps pane are the same thing: both open System
Settings and float a helper panel beside it. Apple dropped per-app anchors from
that deep link, so it always lands at the top of the pane and finding the row is
the real work — the panel carries the row as macOS draws it, one sentence naming
what's left, and a replica that animates the clicks: untick **Desktop**, turn
**Play sound for notification** off.

**Done** moves to the next app; you say so rather than trill watching, because
without Full Disk Access there is nothing to observe. Where trill *can* read,
the panel ticks apps off as macOS agrees — the subtitle shortens, the sentence
narrows to what's left, and the replica drops the step you've done.

The helper only walks the apps the audit that opened it named, and **Silence…**
is offered only for apps trill draws: silencing one trill isn't drawing
de-duplicates nothing, it just loses the notification. Widening to every app on
the Mac takes typing `--all`.

On macOS 26 (Tahoe) the pane is a **Desktop** checkbox plus a
Temporary/Persistent choice that only applies while Desktop is ticked, where
macOS 14 and 15 have a None/Banners/Alerts radio. Notification Center and Lock
Screen stay ticked either way — trill redraws the banner, it doesn't replace the
notification.

### An app with no row

Some apps macOS holds no switch for at all — `com.apple.SoftwareUpdateNotification`
is the one a real rules file hits. No switch doesn't make them quiet, so `doctor`
still names them and the Apps pane gives them their own card, with the one lever
that *is* yours: route them to the inbox. They never become a step to click
through.
