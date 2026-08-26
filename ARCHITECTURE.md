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
13. "Seen" is decided at ingest and never re-derived: a banner drawn at a
    locked screen is stored **unread**, because nothing afterwards can work
    out who was in front of the screen. Everything that counts what you
    missed — the inbox's unread count, the catch-up card — reads that one
    stamp.
14. A progress tick is an **update, not an arrival**: an event carrying
    `progress` and a `key` replaces the card wearing that key instead of
    stacking or folding beside it, and it is drawn without being stored —
    fifty readings are one build, so only the ending reaches the inbox or a
    digest tally. The card gets one card's worth of screen and then **parks
    as a fin**, filling on the edge for the rest of the build; the ending
    takes the fin down and draws the one card worth drawing. Liveness is
    still the *sender's* job — a fin that stops being ticked comes down on
    `progressStallTimeout`. Two guards keep "replace" from becoming a
    way to lose things: a bar never takes over an **ask** however it was
    keyed (that would drop a question with nobody told and its caller still
    blocked), and a card the user **swatted away** hushes further ticks under
    that key — a driver reporting every two seconds would otherwise put it
    straight back. The ending is not a tick and still lands. Ticks are also
    exempt from the dedupe window, which they would otherwise flush: a long
    build spends more throwaway ids than the window holds.

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
                                      │        + the clock, + the Focus
                                      │          (FocusWatch, read-only)
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
   fullscreen aux                     live (InboxFeed) · search · threads
                                      · pills · unread (the card's click
                                      is the query)
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

- **An unattended ask parks, a running job parks, everything else expires.**
  The dismiss timer lands on `BannerQueue.expire`, not `dismiss`: an `ask`
  whose clock runs out moves to the `parked` bucket and renders as a slim fin
  on the right screen edge (`BannerGeometry.Ledge`, `LedgePanelController`)
  until it's answered, dismissed, resolved, or evicted. So does a **progress
  tick** — a rebuild lasts twenty minutes and a card lasts six seconds, so a
  bar that simply expired took the rest of the build with it. Its fin fills as
  the ticks come in, the ending takes it down and banners, and a fin whose job
  goes quiet for `progressStallTimeout` comes down by itself. Only the clock
  parks — a user's own dismissal means they saw it, and swatting a bar's fin
  hushes its ticks the way swatting its card does. Hovering a fin is queue
  state too (`setParkedHover`), so the slid-out card survives rebuilds like
  any panel. The bucket is mirrored to its own sqlite table on every change
  and restored at launch (`AppDatabase.saveLedge`/`parkedLedge`,
  `BannerQueue.restoreParked`), because a question that evaporates on a
  crash is exactly what the ledge exists to prevent; anything older than
  `parkedLifetime` is dropped on the way back in. **Questions only**, in both
  directions: the build a job's fin was reporting died with the daemon, and a
  bar frozen at 40% that nothing will ever finish or take down is the one fin
  that cannot be true. A tick is not history anywhere else either.
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
The probe checks existence, readability, expected tables **and the columns the
reader actually reads** before any session; drift produces
`unavailable(reason:)` — a settings string, not a crash. A table-name probe
alone is not enough: `record` surviving an update with `data` renamed would
pass it and then decode nothing, forever, quietly.

The M3 spike ran on macOS 26.5 (2026-08-25) against this Mac's own store.
What it found, and what the ingest is shaped by:

| Question | Measured |
|---|---|
| Do rows appear promptly? | **No — ~5.14 s late.** Twice: 5137 ms and 5143 ms between `display notification` and the row being visible to a reader. usernoted batches; `delivered_date` is accurate to ~65 ms of the real event, so only *visibility* lags. |
| WAL-watching or polling? | Neither buys latency — the `-wal` file changes in the same instant the row appears. Watching wins on cost, not speed, so the watcher is a `DispatchSource` on the log with a 15 s sweep behind it. |
| What lands under a per-app switch that's off? | **Everything.** Apps with the master allow bit clear (`com.apple.MobileSMS`, `com.apple.mobilephone`, `com.apple.Photos` here) still write records. `record.style` is 1 only when macOS drew something itself and 0 when it didn't — which is exactly the signal that makes "silence Apple's, keep trill's" work. |
| Which fields survive? | `req.titl`, `req.subt`, `req.body`, `req.thre`, `req.cate`, `req.durl`, `req.unct`; `app` in canonical case; `date` in the 2001 epoch. Title is *optional* — Tips and Find My post without one. `body` is a `String` **or** a localization triple `[key, sentence, args]`. |
| Can destination metadata open the right place? | Only sometimes, and never as a URL trill will open: `req.durl` is `messages://…`, `x-apple-tips://…`. The Open pill activates the app instead, which is where Apple's own banner would land you. |
| How aggressively are rows pruned? | Not by age — rows live as long as the item sits in Notification Center (three days' worth here). The watermark, not a time window, is what stops a launch replaying them. |

**The verdict: ship it, opt-in and experimental, and say the number.** A
mirrored card is five seconds late by construction, which is the right trade
for "one banner instead of two" and the wrong one for anything time-critical.
Nothing outside the daemon can close that gap, so the honest move is to
document it rather than design around it.

Two rules the ingest can't be built without:

- **trill never mirrors trill.** `SystemMirrorMapper.ownBundleIDs` excludes
  every id in the family, by identity rather than by "did we just send this" —
  a mirror that reads its own banners draws, records, re-reads and draws
  again. The loop has to be impossible, not unlikely.
- **The `_SYSTEM_CENTER_:` prefix is stripped.** usernoted files daemon-posted
  notifications under a prefixed twin, so `com.apple.SoftwareUpdateNotification`
  appears twice. They are one app to the person reading the banner, and asking
  someone to write a rule naming an internal prefix is asking them to know it
  exists. The raw identifier survives in `metadata.bundleId`.

### Reading the Focus (and never writing it)

A Focus is the user having already answered "should this interrupt me". So
`PolicyEngine` takes it as an input beside the clock — `SystemFocus`, read by
`FocusReader` — and routes what would have bannered: **chatter to the inbox,
faults through unchanged, an `ask` straight to the ledge.** That last one is
the whole reason this isn't just "quiet hours with a different trigger": an
`ask` has a caller blocked on it, and a question silently filed is a process
waiting forever for an answer nobody was shown. It parks as a fin instead —
the same place an unattended question already goes when its clock runs out,
answerable, evictable, and watched by any `--until` poller
(`BannerQueue.park`, the second door onto `expire`'s ledge).

`critical` punches through a Focus exactly as it punches through quiet
hours — one rule, not two kept in step — and **quiet hours have the last
word** over whatever a Focus decided, including the fin: "22:00 to 07:00,
nothing on this screen" means the edge of it too. Everything is tunable
per kind in `rules.json` under `focus`, layered over trill's defaults so
naming one kind never silently clears the others; whether trill looks at
Focus at all is `focusAware` in `config.json`, beside shyness.

**Where the state lives.** `~/Library/DoNotDisturb/DB/Assertions.json`, plain
JSON in the user's own home — not a TCC-protected container like the
notification-settings store. Measured on macOS 26.6, 2026-08-25, both ways:
with nothing asserted the `storeAssertionRecords` key is *absent* (not empty),
and with Do Not Disturb on it holds one record whose
`assertionDetails.assertionDetailsModeIdentifier` is
`com.apple.donotdisturb.mode.default`, written within a second of the Control
Center toggle. `ModeConfigurations.json` names the same four identifiers this
Mac has — Do Not Disturb, Work, Personal, Reduce Interruptions — so the label
path is real and not a fallback nobody exercises. Two things about the shape
are load-bearing:

- **Only `storeAssertionRecords` says a Focus is on.** Ending one does not
  delete its record so much as move it to `storeInvalidationRecords`, which
  is therefore a history of every Focus this Mac has ever finished. A reader
  that counted both would report a Focus from March, permanently.
- **The name is in a second file.** `ModeConfigurations.json`, keyed by the
  same mode identifier. It is used for a label and nothing else — a Focus
  trill can see but can't name is still a Focus.

It is read at the instant a decision is made, memoised for a second, with no
timer and no watcher: the answer is only ever needed once per delivered
event, so reading it *then* is both cheaper than polling and impossible to
miss a change with. And because the source is a file, the reading has
**three** verdicts like the settings audit does — on, off, and *can't tell* —
and can't-tell **fails open**: trill decides exactly what it would with no
Focus at all, and says so in Settings. Silencing somebody's chats on the
strength of a file that changed shape under a macOS update is the failure
that case exists to prevent.

**Nothing here writes.** Not the assertion store, not the pane, not a private
API, not "just a Shortcut". Turning a Focus on or off changes the whole Mac
to change trill's banners, and it is the desktop's dial — haus's "Hush" lane
— and the user's click. Settings shows which Focus is on and offers a button
that opens System Settings → Focus. That is the entire offer, and it is the
same shape as the native-banner helper: read Apple's state, name it, open the
pane, stop.

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

### You come back to a Mac that was busy

The night case, which on a machine with agents on it is most nights: the
screen locks at 23:00, four lanes finish, two of them ask something, one
build breaks, and every card of it is drawn to a lock screen nobody is
looking at. At 08:00 the honest thing to say is not those seventeen cards
again — it is *while you were away — 2 asks, 1 fault, 14 notes*.

Three pieces, and the first one is the reason the other two can be simple.

**Presence is pushed.** `PresenceSentinel` listens to
`com.apple.screenIsLocked` / `screenIsUnlocked` (distributed notifications,
no entitlement) and to `NSWorkspace`'s sleep, wake and session-switch pair.
It never reads the system — the exact opposite of `ScreenWatch`, which has to
poll because nothing reports screen capture. The decision on top of those
signals is `PresenceLog`, a pure struct, and two of its rules are load
bearing: **the first departure wins the timestamp** (lock at 23:00 then sleep
at 23:30 is one absence beginning at 23:00, and restamping it would silently
drop half an hour of traffic), and **waking onto a lock screen is not coming
back** (the card would be drawn, time out and be gone before the password was
typed — the unlock is the return). A Mac that never locks posts no unlock, so
for that Mac the wake *is* the return. The log persists to `UserDefaults`,
because the case that most needs a card — locked at 23:00, rebooted at 03:00,
logged into at 08:00 — spans a process that wasn't running.

**Unread is where the count comes from,** which is only true because ingest
records it truthfully. `AppDatabase.insert` takes presence alongside the
decision: a banner drawn at somebody is read, a banner drawn at a locked
screen is not. That is a one-line change with the whole feature behind it —
without it every card that played to an empty room is stored as "seen", and
the night vanishes from the inbox's unread count as well as from this card.
It can only be decided at ingest; nothing afterwards can work out who was
sitting there.

**The card is a tally, and the click is a query.** `missedCounts(since:)` is
one `GROUP BY` over a `kind` column lifted out of the payload — six numbers
however loud the night was, with no `LIMIT` that could quietly make the
number wrong. `CatchUpCard` reads them out in `Kind` order rather than by
size: the digest ranks its sources loudest-first because it answers "what was
all that noise", and this answers "what do I have to deal with", where one
ask outranks fourteen notes. The window is capped at a day (a week away is
not a bigger paper, it is an archive, and the archive is the inbox), the card
carries an `InboxScope.since` target so its click opens on exactly the rows it
counted, and **a quiet night draws nothing** — an unlock that always produces
a card is an unlock you learn to dismiss unread.

Like `DigestCard`, it is composed by trill and enqueued **directly**: never
back through the repository, so it is never policied, persisted or deduped,
and it leaves no row in the history it is a summary of.

It **does not hold for quiet hours**, and that is the one place it departs
from the digest. A 3am digest card is trill talking to an empty chair; a 3am
catch-up card is trill answering the person who just unlocked the Mac. It
cannot interrupt anybody by construction — it only ever fires as somebody
sits down.

### The inbox is where the overflow goes

Three surfaces deliberately drop things on the floor, and all three land here.
The ledge holds five fins and a sixth evicts — the oldest *running job* first
and only then the oldest question, because evicting an ask unblocks its caller
with a 75 while evicting a bar costs a progress reading; a digest card is a
count, not a list; quiet hours and an `inbox` rule route whole events past the
screen. None of that is loss, because `AppDatabase` already has the rows — but
it is only *not loss* if the window is one you would actually open.

So the window is a view onto the store and holds no state of its own.
`InboxList` does the work as pure functions — scope, search, thread folding —
and `InboxView` draws what comes back. That is the same split as everywhere
else in trill (`ScreenGeometry`, `PolicyEngine`, `CalendarEventMapper`), and
it is why threads and search are tested without a display.

**Live, and not by polling.** `InboxFeed` is one `@MainActor` observable owned
by `AppRuntime`: a revision counter bumped once per delivered event, the set of
ask ids currently on the ledge, and which database to read. The bump happens
in the delivery loop *after* `EventRepository.ingest` enqueued its insert, and
reads share that write's serial queue — so a window reloading on the signal is
guaranteed to see the row without the feed ever carrying an event. The database
is published rather than handed over at open time, because `persistHistory` is
live: switching history off with the inbox up has to empty it, not leave it
reading a handle nothing writes to.

**Threads fold on the sender's key, never on a guess.** `InboxList.group`
collapses a thread into its newest event exactly the way `BannerQueue` folds a
coalesced banner, and a row sits where its latest message would have sat. An
event with no `thread` is a row of one; nothing infers a thread from matching
titles.

**Unread means trill never put this in front of you.** `AppDatabase.insert`
stamps `read_at` for a `banner` decision — it was drawn on a screen, the
closest thing this app has to "seen" — and leaves it NULL for everything held
back. That is what makes the count worth a title bar: it counts the digest
tallies, the quiet-hours demotions and the `inbox` rules, rather than
re-reporting every banner that already interrupted you. Opening a row marks it
read; the context menu puts the dot back.

**Every performable action draws, except `reply`.** A card is a glance and
stops at `Limits.drawnActions`; the inbox is where the rest survive, which is
what that limit's comment has always promised. The exception is the one action
whose effect is a line written back down the socket the ask arrived on — history
has no socket, and the caller is long gone. Same reason the ledge's restore
path strips pills off a fin that outlived its daemon.

**It does not redact.** Shyness is a rendering rule for cards drawn *at*
someone, and `--redact` is documented as keeping a body off the banner. This
window exists only because the user summoned it, and hiding what they came to
read would break it in exactly the moment they opened it on purpose.

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
