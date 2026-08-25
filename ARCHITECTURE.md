# Trill architecture

## Invariants

1. The compositor never blocks on a provider; ingestion is async streams end
   to end.
2. A provider failure degrades to "off with a visible reason", never to a
   broken pipeline. Supervision re-probes with capped backoff.
3. Provider-native types stop at the provider boundary; everything past it
   is `NotificationEvent`.
4. Apple-owned stores — the `usernoted` db and the `com.apple.ncprefs`
   preference domain — are read-only or not at all: the former only when its
   schema probe passes, the latter decoding defensively and degrading to
   "nothing to report" rather than to a wrong answer. trill never writes
   either, so it can never quietly change a setting the user believes only
   they control.
5. Banner state lives in `BannerQueue` — including what a burst folded in and
   which card the pointer is over; panels are disposable and rebuilt on every
   display-topology change without event loss.
6. Banners never take key focus and never make sound.
7. Notification content never appears in logs; persistence is a user choice
   (off = nothing touches disk).
8. Surfaces render only actions the source can honor (capability
   advertisement, no dead buttons).
9. Policy decisions are pure functions of (event, rules, clock).
10. The wire may *name* a resolver, never describe one: what `--until` runs
    is declared in the user's own `rules.json`, executed as argv with no
    shell, and resolution is one-way — nothing can put an answered question
    back on screen.
11. `trill ask` blocks the **caller**, never the compositor: the daemon holds
    a socket open, not a thread. Every ask resolves exactly once — first
    resolution wins — and no outcome but a pressed pill is an answer.
12. Screen-share shyness is a *rendering* rule, not a queue one: when macOS
    says the screen is being watched, cards draw their redacted form, and the
    events behind them are untouched — nothing is dropped, held back, or
    written differently.

## Boundaries

```text
trill CLI ──socket──► SocketProvider ─┐
pounce / perch / scripts (same lane)  │        probe() → ProviderHealth
                                      ├──► EventRepository (actor)
usernoted db2 ──read-only──► SystemMirrorProvider   normalize · dedupe
              (quarantined, schema-probed)          persist · supervise
                                      │
GitHub ──webhook──► tunnel ──► GitHubWebhookProvider
   (HMAC-gated; tunnel = haus's wiring)
                                      │
EventKit ──push──► CalendarProvider   │
   (in-process; read-only grant, opt-in)
                                      │
                        PolicyEngine (pure) ── rules.json, hot-reloaded
                                      │
        SettingsView ◄── AppSettings ── config.json, hot-reloaded
              (the file is the truth; UserDefaults holds only ephemera)
                                      │
              ┌───────────────────────┼─────────────────────┐
              ▼                       ▼                     ▼
        BannerQueue             inbox (sqlite)      DigestScheduler
 coalesce · pause/expand · capacity · park │          tally, flush on the hour
              ▼                       ▼                     │
      BannerWindowSystem          InboxView ◄───────────────┘
   NSPanel per banner · all Spaces ·  scoped: all · asks · one digest
   fullscreen aux                     (the card's click is the query)
              ▼
        ActionRouter ── open app · open URL · focus lane · open event ·
                        open inbox · silence native · reply (answers an ask) ·
                        (hooks, M2)
              │
              ▼
          AskBroker ──── the reply half of `trill ask`: who is still on the
                         wire, and the one line written back to them
```

## The hard cases

### A provider dies, hangs, or floods

Each provider runs in its own supervised task: `probe()` gates entry, a
finished stream triggers re-probe with exponential backoff (1s → 60s cap),
and health is queryable for settings. Ingest is one actor hop; a flooding
provider hits the dedupe window and field caps in `normalized()`, and the
socket server cuts any peer that streams a megabyte without a newline.

### Display topology changes mid-burst

`BannerWindowSystem` rebuilds panels on
`didChangeScreenParametersNotification` (perch's pattern). Because visible,
waiting and parked entries all live in `BannerQueue`, a rebuild is pure
re-presentation — the ledge's fins are torn down and redrawn like banners. Capacity shrink pushes overflow back into the waiting line
— covered by unit test, no display required, thanks to the pure
`ScreenDescriptor`/`BannerGeometry` split.

### More than one display

A rule may say *where*, not just whether: `"display": "builtin"` beside
`delivery`, resolving to `primary` (the menu-bar display, and the default),
`active` (the one the pointer is on), `builtin` or `external`. The policy
engine answers with a `DisplayTarget` on `.banner` — an intent, never a screen
id, because what "the external one" means changes every time something is
plugged in.

`DisplayRouter` (pure) turns that intent into one of the attached
`ScreenDescriptor`s, and **every target falls back to primary**: a rule naming
a monitor you unplugged must still put its banners somewhere. The queue counts
a column **per resolved screen**, not per target — on a laptop with nothing
attached, `builtin` and `external` are the same display and share its room,
where per-target counting would draw two stacks over each other. Hover pauses
the display it happened on and no other; the overflow badge is per column, so
"⌄ 2 waiting" always names the screen you are looking at.

The target is resolved once, on arrival — `active` means the display you were
facing when the card landed, not wherever the pointer went next — and again on
every topology change, which is what carries a monitor's cards home when it
comes back. Cards for a display that isn't attached wait; nothing is dropped
for want of a screen.

### The screen already has furniture on it

`NSScreen.visibleFrame` knows about the menu bar and the Dock and nothing
else. Someone running a third-party bar (sketchybar, a status HUD) with the
menu bar auto-hidden has a strip at the top that AppKit calls free and they
call occupied — banners landed on top of it — and a tiling window manager
leaves an outer gap that a card 12pt from the screen edge misses by a few
points, which reads as a mistake rather than as a choice.

So placement measures the desktop instead of assuming it.
`DesktopLayoutProbe` (Platform) asks the window server for on-screen bounds,
`DesktopLayout` (pure) decides what they mean, and the answer lands in
`ScreenDescriptor.contentFrame`; `BannerGeometry.anchor` is the single place
every other function measures from. Two rules, both written against *shape*
rather than any app's name:

- **A bar is an overlay that spans nearly the whole display and hugs an
  edge.** It is subtracted from the usable frame. A narrow overlay is a HUD
  and a tall one is a curtain (the wallpaper, a screen tint) — neither
  shortens the screen.
- **The rightmost ordinary window in the top half of the display donates its
  top-right corner.** The stack hangs from *that* point, so it reads as one
  more pane of the layout. A window taller than the usable frame is
  fullscreen or is sitting over the bar; its corner is not a gap anyone
  chose, so it is ignored. With nothing to line up with, the anchor is the
  usable frame inset all round — the behaviour that shipped first.

`DesktopLayoutProbe` deliberately does **not** pass
`.excludeDesktopElements`: sketchybar draws at `kCGBackstopMenuLevel` (-20),
so the flag that sounds like "skip the wallpaper" also skips the bar the rule
exists for. It reads bounds, level and pid only — never `kCGWindowName`, and
trill never asks for Screen Recording. A notification compositor that reads
window titles is the thing this app promises it isn't.

### Bursts

Thread-mates arriving inside the coalesce window fold into the existing
banner instead of stacking: the newest wins the face, "+N more" is the
receipt. Beyond visible capacity, entries queue; hover pauses rotation so
banners never swap under the cursor.

**The fold keeps its events, hover opens them, and every line is a button.**
"+9 more" alone is a number you can't do anything with — it says a burst
happened without saying what was in it, and the nine events it stands for were
already thrown away by the time you read it. `BannerQueue.Entry` therefore
carries the folded events (newest first, bounded by `foldPreviewLimit`; the
*count* is tracked separately so trimming the list can never make the banner
under-report), and hovering the banner opens it downward into that list.
Hover already froze the dismiss clock, so the list stays up exactly as long as
you're reading it, and a burst you don't look at costs nothing it didn't cost
before.

**The screen sets the row count — there is no magic number.**
`BannerGeometry.foldRowCapacity(on:above:cardHeight:)` answers how many rows a
card at a given place in the stack can grow before its own bottom edge leaves
the visible frame, and that is the cap. (It takes the *height* already spent
above the card, not an index — cards vary in height now that a pill row
exists, so the caller sums real sizes via `heightAbove`.) A ten-message thread lists all ten because ten fit;
a two-hundred-message one lists what fits and admits the rest in a single "and
N earlier". This replaced a fixed four-row list, which meant a normal burst
couldn't be seen in full at any screen size — `foldPreviewLimit` sat at 8 and
was the real ceiling, so it is now a memory backstop well above any display's
row capacity rather than the thing you feel.

Only the *collapsed* cards above the hovered one count against that capacity.
Cards beneath it are allowed to be pushed off screen — they stay in the queue
and return on unhover — because stopping the fold at whatever happened to
arrive under it would make the same burst a different height depending on
unrelated traffic. `BannerWindowSystem.render`'s collapse fallback therefore
guards only the hovered card's *own* frame; it used to collapse the expansion
whenever any card in the stack lost its slot, which capped every fold at the
traffic below it.

**Each row runs its own event's action.** The face is one target and every
listed thread-mate is another, so the fold is a list of things you can act on
rather than one big button wearing a list. A row click runs
`performDefault` for *that* event and then dismisses the whole banner: you
opened the thread to deal with it, and you have. A row whose event advertises
no action gets no highlight and no click — `NotificationEvent.hasDefaultAction`
is the single predicate the router branches on and the view draws from, so
trill cannot start drawing dead buttons. The "and N earlier" line is never
pressable: it stands for several events, so there is no one thing to do.

Three more consequences worth knowing:

- **An unattended ask parks; everything else expires.** The dismiss timer
  lands on `BannerQueue.expire`, not `dismiss`: an `ask` whose clock runs
  out moves to the `parked` bucket and renders as a slim fin on the right
  screen edge (`BannerGeometry.Ledge`, `LedgePanelController`) until it's
  answered, dismissed, resolved, or evicted by a sixth ask. Only the clock
  parks — a user's own dismissal means they saw it. Hovering a fin is queue
  state too (`setParkedHover`), so the slid-out card survives rebuilds like
  any panel. The bucket is mirrored to its own sqlite table on every change
  and restored at launch (`AppDatabase.saveLedge`/`parkedLedge`,
  `BannerQueue.restoreParked`), because a question that evaporates on a
  crash is exactly what the ledge exists to prevent; anything older than
  `parkedLifetime` is dropped on the way back in.
- **Which banner is hovered is queue state, not panel state.** Expanding one
  card re-lays every card beneath it, so the render pass has to see it —
  `BannerQueue` holds a `hoveredID` (an id, not a bool) and stamps
  `Entry.expanded`. Exit only clears the hover it owns, because entering B
  can beat leaving A. Dismissing the hovered banner clears it too: SwiftUI
  doesn't reliably send an exit for a view that vanishes under the cursor,
  and a hover left set would pause the queue forever.
- **The expanded height is computed, never measured.** `BannerGeometry
  .cardSize` is the single arithmetic both `BannerView` and the panel size
  themselves from, and the view takes its row count from
  `foldListedCount`/`foldRowCount` rather than repeating it — the card's
  height is fixed, so a view that drew one row more than the height paid for
  would clip it silently. `NSHostingView.fittingSize` is stale in the same
  turn as the state change that grew the view on macOS 26; measuring settles
  the panel on the previous height (the bug pounce's filter row shipped once).
  The row cap is *passed down* rather than derived: it depends on the screen
  and on the card's index in the deck, and `BannerView` knows neither and must
  not learn. `BannerWindowSystem` computes it once per render, bounds it a
  second time by what the fold actually kept (`folded.count + 1`, the `+1`
  being the eventless "and N earlier" line), and hands the same number to both
  `cardSize` and the view — so the height can never pay for a named row the
  view has no event for.
- **Privacy is per event, in the list too.** A `redacted` thread-mate keeps
  its body to itself even when the face of the fold is visible — the fold is
  a rendering of many events, not an inheritance from one.

### Someone is watching the screen

**macOS has no API for "is my display being captured".** `NSScreen` has no
`isCaptured` (that one is UIKit's), `CGDisplayIsCaptured` has been unavailable
since 10.9, `CGSessionCopyCurrentDictionary` carries no such key, and nothing
is posted on the Darwin or distributed notification centres when a capture
starts or stops — all four measured against the macOS 26.5 SDK on 2026-08-25.

What macOS *does* do is draw its own in-use indicator, and that window is
readable without any permission: a 28×28 window at the cursor window level
whose top-right corner sits 3pt inside the display's, at the end of the menu
bar. `ScreenWatch.evaluate` is the whole decision, pure over one
`ScreenWatchSnapshot` (windows at that level, display rects, mirroring), and
`ScreenWatchSentinel` is the only part that talks to CoreGraphics.

Three things follow from the signal being an *indicator* rather than a
capture flag:

- **It cannot tell screen capture from a live camera or mic** — measured
  identical for `screencapture -V` and for an open microphone. trill treats
  all three as an audience and says so in Settings rather than claiming to
  know which. For a compositor that is the right side to be wrong on: those
  are the same minutes.
- **The window name is never read.** `kCGWindowName` needs Screen Recording
  permission; an app that asked for the screen in order to be shy about the
  screen would be a joke. Level, bounds and on-screen-ness come back
  ungranted, and they are enough.
- **It is polled, because nothing notifies** — 2s while cards are on screen
  or the Settings readout is open, nothing at all otherwise, plus a
  synchronous reading whenever a card is about to be drawn, so a banner can
  never out-run the poll onto a shared screen. The window-list call measured
  3–5ms warm.

Mirroring rides the same verdict (`CGDisplayIsInMirrorSet`, hardware mirrors
excluded): a projector is an audience too, and that one *is* documented.

The compositor treats a change in shyness exactly like a display-topology
change — re-render every panel from queue state. `BannerView` is handed a
`shy` flag the same way it is handed `maxFoldRows`: it renders what it is
told and cannot ask.

### A stack of distinct banners

Separate sources get separate cards in a spaced column: each keeps
`BannerGeometry.gap` points from the card above it and rides a panel with a
real shadow (`hasShadow`, invalidated on every frame change). An earlier
version *dealt* the cards instead — each lapping 6pt over its elder for a
pile-with-depth look — and feel-testing voted it out: the lap read as banners
colliding, and hiding an elder's bottom edge cost more than the depth bought.
Z-order still runs newest-in-front (panels created newest-last with
`orderFrontRegardless`), which only matters while a hovered fold grows over
its neighbours.

Capacity is the screen's: `BannerGeometry.capacity` counts what fits inside
the anchor rect and `BannerWindowSystem.syncCapacity` passes it straight
through. (A `min(capacity, 3)` clamp sat there from the first feel-test; it
made every display behave like a laptop.) When the queue still holds more
than fits, a mouse-transparent "⌄ N waiting" badge hangs off the bottom
card's trailing corner (`OverflowBadgeController`) — a report, not a control.

`BannerGeometry.step` — a lateral offset per card, fanning the stack
leftward — is **deliberately 0**. The fanned version went to a feel-test and
the drift read as misalignment rather than depth, worsening the deeper the
stack went. The knob stays so the idea isn't rediscovered and re-shipped.

Because a hovered fold makes one card taller, placement can't be a closed
form per index: `BannerGeometry.stackFrames` walks the whole stack
cumulatively and returns nil for any card that would leave the visible frame
(and everything after it). The compositor drops those panels and the queue
keeps the events, so a card pushed off the bottom comes back on the next
render.

**A card pushed off by an expansion is fine; the expanded card itself is
not.** Losing the tail is the intended outcome — that is how a fold gets to
fill the screen instead of stopping at whatever traffic happened to arrive
under it, and those entries are still in the queue. So the fallback in
`render` re-lays with the expansion dropped only when the *hovered* card's own
frame comes back nil, never when some card below it did. (It used to fire on
any missing frame, which capped every fold at the cards beneath it.) Guarding
that one card is not cosmetic: closing the panel *under the pointer* would
strand the hover — no exit event follows a panel that is simply gone — and a
hover left set pauses the queue for good. Since `foldRowCapacity` sizes the
expansion to fit in the first place, the fallback should never actually fire;
it stays as the honest failure if it ever does. Same reasoning covers the
other path that can take a hovered card away without an exit: `setCapacity`
clearing the hover it just pushed into the waiting line.

### A question that answers itself

Three roads take a fin off the ledge without a human: `trill resolve KEY`
over the socket, an event that arrives carrying `resolves` (the GitHub
bridge's own merge/close deliveries answer the review-request ask they
share a name with), and a poller the daemon runs for a parked ask that named
one with `--until`. All three end at `BannerQueue.resolve(keys:)`, which
clears matching entries from visible, waiting and parked alike — three
feeders, one terminal, no second path to keep in step.

An event answers to its id and, if it has one, its `key`. The id is the
common case: `trill send` already printed a name for the event, so a script
that sends and later resolves needs no key at all. A key is a *second*
name, for when the resolver is a different process — a webhook arriving with
its own delivery id, tomorrow's rebuild hook, a lane that respawned — and
re-sending an ask under the same key replaces its fin instead of growing a
second one.

The poller is the part that had to be designed rather than written. Anything
local can write to trill's socket, so a command string on the wire would make
the daemon a run-this-for-me-on-a-timer service for every process on the Mac,
in a GUI session that may hold Full Disk Access. Instead `--until NAME[:args]`
selects from a `resolvers` map in `~/.config/trill/rules.json` — the file only
the user writes — and the wire contributes arguments, which fill numbered
holes (`$1`…`$9`), may not start with `-` (so `gh pr view $1` cannot become
`gh pr view --repo elsewhere`), and are percent-encoded to the unreserved set
when the resolver is a URL. `Resolver` decides all of this purely and hands
`ResolverRunner` a `ResolverPlan` with nothing left to interpret; the runner
is the only place in trill that starts a process, and it starts it through
`/usr/bin/env` with an argv and an environment the plan carries whole — there
is no shell in the path, so there is no string a quote could break out of.

Bounded in every direction that could bite: `every`/`timeout`/`giveUpAfter`
are clamped on decode, `giveUpAfter` counts from the *event's* timestamp so a
relaunch can't hand a stale ask another twelve hours, a check that can't run
(env's 126/127 included, which would otherwise read as a patient "not yet")
counts as a failure and five in a row stop the poller, and a poller that runs
out of time leaves the fin up. Resolution never invents an answer it didn't
get, and `ResolutionMonitor` arms and disarms purely by reconciling against
the parked list — so every way a fin can leave, including a relaunch, stops
its poller through the same one path.

### A meeting that moves

The calendar source is the only one where the *truth changes after trill has
already decided something*. A 2pm standup can move to 2:30, be declined from a
phone, or be deleted outright — and the machine can be asleep through all of it.

Three rules cover the whole space, and each exists because the obvious
implementation gets it wrong:

- **The schedule is rebuilt whole, never patched.** `EKEventStoreChanged` says
  *something* changed, not what; re-querying is both simpler than a diff and
  the only version that can't drift. Deletion, decline and reschedule are all
  just "the answer is different now".
- **An occurrence is named by item id *and* start time.** A recurring event
  shares one identifier across every instance, so the start has to be part of
  the name — which also means a *moved* meeting is a new occurrence that earns
  its own banner, rather than one the dedupe window swallows.
- **The tick is a wall-clock timer, and a missed reminder is still owed.** A
  monotonic timer measures uptime, and the Mac sleeps through most of any lead
  time. So the deadline is `wallDeadline`, and "is it due" is asked of the fire
  date rather than of a window — a reminder whose moment passed during sleep
  still banners, right up until the meeting itself has started (`grace`), after
  which the occurrence is marked seen and stays silent. trill does not tell you
  about a meeting you are already in.

The banner is a `note`, not an `ask`, and that is a decision rather than an
omission: an `ask` that times out parks on the ledge until something answers
it, and nothing ever answers "your 2pm is in ten minutes". It would still be
sitting there at five, still claiming ten minutes.

### The undocumented mirror

`SystemMirrorProvider` treats the usernoted store the way any undocumented
Apple store deserves: independently probed, explicitly enabled, never assumed.
The probe checks existence, readability, and expected tables before any
session; drift produces `unavailable(reason:)` — a settings string, not a
crash. Ingest (WAL-watching vs polling, Focus interaction, per-app field
survival) is deliberately unimplemented until the PRD's spike answers those
questions on real macOS versions.

### Suppressing Apple's banners

There is no public "become the notification renderer" entitlement, so trill
does not claim the capability. The supported route is the Hush-backed mode:
a Focus profile (owned by the rice) silences Apple's rendering while
providers still see events; trill deep-links to Notification and Focus
settings via `SystemIntegration` — the one file allowed to touch Apple's
notification machinery.

What trill *can* do is tell you when Apple is still drawing something it's
also drawing. `NotificationSettingsAudit` reads the private per-app store
behind that pane and decodes four bits per app: the on-screen
alert (`1<<3` Temporary, `1<<4` Persistent, neither = the **Desktop** checkbox
is clear), play-sound (`1<<2`), and **allow-notifications (`1<<25`)**.

**Which file that is, is the whole trap.** On macOS 26 it's
`~/Library/Group Containers/group.com.apple.usernoted/Library/Preferences/group.com.apple.usernoted.plist`.
`com.apple.ncprefs` — the domain every article names, and the one trill
shipped against first — is a *stale mirror*: it still carries an `apps` array
of plausible `flags`, so nothing about reading it looks wrong. Measured on a
26.6 machine: the entire 92-app store was byte-identical to a copy 17 days
old, across a settings change and 45 minutes of watching, while the group
container took that same change within seconds. A helper panel polling
ncprefs for "did you flip it yet?" therefore never says yes.

The group container is TCC-protected, so this read needs **Full Disk
Access** — the same grant System Mirror wants. That gives the audit **three**
verdicts rather than two: noisy, quiet, and *can't tell*. `readAll()` returns
nil for the third, `trill doctor` exits 5, Settings says "can't tell", and the
helper still walks the user through but confirms nothing. "Can't tell"
rendering as "all clear" would be trill reassuring someone about a file it
never opened.

macOS 26 (Tahoe) reshaped the pane without moving the bits: the old
None/Banners/Alerts radio became a Desktop checkbox plus a
Temporary/Persistent choice that only applies while Desktop is ticked. Worth
knowing because the helper *demonstrates* those controls — a demo miming a
radio button that no longer exists is worse than no demo, so the vocabulary in
`DesktopAlert` deliberately tracks the pane rather than the bit names.

That last one is the one that matters most, and it was learned the expensive
way. macOS leaves the style and sound bits frozen at their last values when
the master switch goes off, so an audit that reads only style and sound
reports every app the user has *already* silenced — the first cut of this
shipped exactly that bug and told the user to go turn off Calendar, ghostty
and Chrome, all long since off. It's now pinned in `NotificationSettingsAudit
Tests` against 19 apps whose real state was read straight off the System
Settings pane, with the single known miss (an app never prompted for
authorization, `auth == 0`) asserted as a miss rather than hidden.

Bits with plausible-but-uncorroborated community meanings are deliberately
**not** read. Bit 29 is the cautionary tale: it looked like a fine candidate
for the allow bit until its set turned out to match the community's
"time-sensitive apps" list almost exactly — corroboration is what ruled it
out, and nothing else would have.

That audit is what `trill doctor` reports and what the stepped helper panel
(`OnboardingAssistantView.Mode.nativeBanners`) polls once a second while the
user works in System Settings. The panel is the Full Disk Access assistant's
shape reused wholesale — non-activating, all-Spaces, deterministic height —
because the constraint is identical: be readable *beside* System Settings
without taking its focus.

### A digest rule batches nine things

`delivery: digest` stamps an event `digest:<name>` and stops there — no
banner, an inbox row like any other. `DigestScheduler` rides the same
delivery stream the compositor does and keeps a **tally** per name: a total,
a count per source, and the earliest event timestamp it has seen. Not the
events — a digest rule pointed at a firehose would otherwise be an unbounded
in-memory buffer of exactly the events the user asked not to see, and the
events are already in sqlite.

On the hour it hands the queue one card per name (`9 quiet things · ci ×4,
garden ×3`), composed by `DigestCard` and enqueued **directly**. It never
re-enters the repository: a rule matching `source: trill` could otherwise
digest the digest, and the card would be persisted and deduped for no gain.

The card carries one `open_inbox` action whose target is an `InboxScope`
(`digest:<name>@<epoch>`), so the click is a query — `AppDatabase.digest
(named:since:)` — rather than a second store of what the card counted. The
same scope type backs `trill inbox --asks`, so there is one answer to "which
slice of history is this window".

Quiet hours **hold** a flush rather than skipping it. A 3am card is the one
interruption the feature exists to prevent, and dropping the tally would lose
the count silently; the first flush after the window says "23 quiet things"
instead of nine. The ticker sleeps in ≤10-minute hops against a wall-clock
deadline, so a Mac that slept through the hour flushes on the way back rather
than an hour later.

### A caller is blocked on the answer

`trill ask` turns a banner into a return value: the CLI writes one request and
then simply doesn't exit, and the daemon replies when a pill is pressed —
minutes later, from the main actor, down a socket the socket queue is still
holding open. Nothing else in trill answers late, and the shape that makes it
safe is `AskBroker`: a lock and a dictionary of who is waiting, keyed by event
id, with the rule that **an ask resolves exactly once and the first resolution
wins**.

That rule is load-bearing rather than defensive, because the ways an ask ends
routinely race:

- a pill is pressed — `ActionRouter` answers the broker, then the queue takes
  the banner down, and a takedown is *itself* an abandonment. The answer got
  there first, so the abandonment is a no-op;
- the user dismisses it, a sixth ask evicts it off the ledge, or something
  resolves it (`trill resolve`, an event carrying `resolves`, a `--until`
  poller that came good) — all of them land on `BannerQueue.onDropped`, the
  queue's "this left for good" callback. Parking is not leaving: a parked
  question is still being asked, and its caller is still blocked;
- `--timeout` expires, or the caller hangs up — the broker retracts the banner
  through the queue, because a question nobody is behind must not stay
  pressable;
- no banner is ever drawn, because a rule dropped the event or quiet hours
  demoted it. A claim watchdog reports that in seconds instead of blocking the
  caller for a timeout it will never earn.

An unanswered ask exits 75, never 0, whichever of those it was — the CLI's exit
code is the pill's index, so silence has to live somewhere it can't be mistaken
for consent. The rest of the pipeline is unchanged: an ask is a normal
`NotificationEvent` whose pills are `reply` actions the *daemon* mints, so a
sender can't write a banner whose Deny answers 0. The ledge's restore path
strips them: a fin that outlived its daemon outlived the socket its answer
would have gone down.

## Planned extensions that fit existing seams

- Per-digest schedules: `DigestSchedule` is one pure function over `now`;
  a rule-declared cadence replaces it without touching the scheduler.
- Pounce inbox: `trill history --json` over the socket, rendered by a
  pounce command.
- Provider actions (chat reply, dismiss-at-source): richer capability sets on
  existing providers. Calendar's `open_event` is the shape they take — a named
  capability with a validated target, not a URL on the wire.
- Nebelung theming, second half: kind hues already arrive through
  `~/.config/trill/theme.json` (`BannerTheme`, system-color fallbacks);
  surface/text tokens would ride the same file.
- Command hooks for *actions*: `ActionRouter.command` gains an allowlisted
  runner, declared in `rules.json` the way `resolvers` already are.
