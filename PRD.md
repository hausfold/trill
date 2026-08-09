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
  key; top-right stack — cards dealt downward, overlapping, newest in front;
  hover pause; burst coalescing by thread, folded into one card that opens
  into a list on hover; Reduce Motion respected; redacted privacy level.
- Inbox window + minimal settings (login item, persistence, provider
  health, deep links to Apple's Notification/Focus settings).
- `trill doctor [--all] [--notify] [--json]`: reads Apple's per-app
  notification preferences read-only and reports the listed apps macOS
  still banners or sounds itself (exit 4 when any). `--notify` reports as
  banners whose one action opens a stepped helper panel beside System
  Settings — animated, live-polled, one app at a time. trill never writes
  another app's settings.

### M2 — rules that earn the name

Digest flushing on schedule, per-source styling hooks, `trill history
--source X --since 2h`, `trill watch --json`, pounce integration, Hush
handshake (enable Focus profile ↔ trill takeover), opt-in command hooks
with redacted environment.

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
15. Send three events from three different `--source`s: three cards flush to
    the same right edge, each lapping over the bottom of the one above it and
    drawn in front of it, all three still readable — a stack, not a spaced
    list.

## Non-goals (v1)

- Capturing other apps' notifications (that's M3's question, not v1's
  promise).
- Suppressing Apple's banners programmatically.
- Invoking arbitrary notification action buttons of other apps.
- Windows/Linux, cloud sync, accounts, telemetry.
