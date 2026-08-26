# Other apps' notifications

Three lanes, in order of honesty.

## 1. First-party — anything that can run a command

The socket is the supported road, forever. Scripts, CI, hooks, agents, and the
rest of the [hausfold](https://github.com/hausfold) family speak it directly.
One JSON line in, one banner out. See [the rules file](rules.md).

## 2. System Mirror — experimental, off by default

Reads Apple's `usernoted` store **read-only** under Full Disk Access and
redraws other apps' banners in trill's language. The bundle id is what rules
match on, so `com.apple.MobileSMS` is Messages. Turn it on in **Settings ▸
Sources**.

It's an undocumented surface, so it's quarantined: the database is opened
read-only, its schema — tables *and* the columns the reader reads — is probed
before every session, and any drift disables the source with a visible reason
rather than breaking the pipeline. trill stays fully useful without it.

**A mirrored card arrives about five seconds after the notification itself.**
usernoted batches its writes; nothing outside that daemon can hurry it. The
number is here rather than hidden because it decides what the mirror is good
for. The card's *timestamp* is exact, so a late card still says when the thing
happened.

**Which apps it draws is yours to pick.** Settings' **Apps** pane lists every
app System Settings itself lists, one tick each, and writes them to
`systemMirrorApps` in `config.json`. Leave it alone and the mirror draws
everything it sees; tick a list and it draws exactly that — including nothing,
if you untick everything. Ticking an app later starts it from the present rather
than replaying what it missed.

## 3. Silencing Apple's own banners — yours to click

If macOS is *also* drawing an app trill mirrors, you see everything twice.
trill will tell you which apps those are and walk you to the switch. It will
not throw the switch: **trill reads Apple's notification settings and never
writes them.** There is no API to change another app's notification
preferences, and silently rewriting a pane you believe only you control isn't a
trade this app makes.

### `trill doctor` — the duplicate-banner check

```sh
trill doctor            # the apps your rules.json names
trill doctor --all      # every app on the Mac
trill doctor --notify   # …and put the findings on screen, click to be walked through
trill doctor --json     # for a hook
```

It reads Apple's per-app preferences read-only and reports every listed app
that still has **Desktop** ticked or **Play sound** on. **Exit 4** means it
found some, so a rebuild hook can gate on it.

"Listed" means the bundle-id-shaped `source` values in your `rules.json`;
`--all` widens it to every app on the Mac, and naming bundle ids explicitly
narrows it.

### Exit 5 is a real answer: *can't tell*

Those preferences live in an Apple group container, which is TCC-protected — so
**`doctor` needs Full Disk Access**, the same grant System Mirror wants.
Without it there is no answer to give, and trill gives that one: `can't tell`,
**exit code 5**. A check that quietly exited 0 while blind would make every
un-granted Mac look clean. Three verdicts, not two.

### The walkthrough

`--notify` puts the findings on screen with one action — **Silence Native
Banners** — and the **Silence…** button beside each app on the Apps pane is the
same thing. Clicking it opens System Settings and floats a helper panel beside
it: the app's row as macOS draws it (Apple dropped per-app anchors from that
deep link, so it always lands at the top of the pane and finding the row is the
real work), one sentence naming what's left to change, and a replica that
animates the clicks — untick **Desktop**, turn **Play sound for notification**
off.

**Done** moves to the next app. trill asks rather than watches because it can't
rely on watching: the store needs Full Disk Access, and on a Mac that hasn't
granted it there is nothing to observe. Where trill *can* read, the panel ticks
apps off by itself as macOS agrees — the row's subtitle shortens, the sentence
narrows to what's left, and the replica drops the step you've already done.

The helper only walks the apps the audit that opened it named, and **Silence…**
is offered only for apps trill draws: silencing one trill isn't drawing doesn't
de-duplicate anything, it just loses the notification. Widening the check to
every app on the Mac takes typing `--all`.

The pane changed shape in macOS 26 (Tahoe): the old None/Banners/Alerts radio is
now a **Desktop** checkbox plus a Temporary/Persistent choice that only applies
while Desktop is ticked. Notification Center and Lock Screen stay ticked — trill
redraws the banner, it doesn't replace the notification.

### An app with no row

Some apps macOS holds no switch for at all (`com.apple.SoftwareUpdateNotification`
is the one a real rules file hits). Having no switch doesn't make them quiet, so
`doctor` still names them and the Apps pane carries them in their own card — with
the one lever that *is* yours: route them to the inbox. What they never become is
a step to click through.
