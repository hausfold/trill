# Copilot instructions

**Read [`AGENTS.md`](../AGENTS.md) at the repo root first — it is the full,
authoritative instruction set for every agent working here, and this file is
only a pointer to it.** (Copilot doesn't follow file imports, hence the
duplication below; if the two ever disagree, `AGENTS.md` wins.)

The short version:

- Trill is a quiet, scriptable **notification compositor for macOS** in the
  [hausfold](https://github.com/hausfold) family: it draws its own silent
  banners for events from local sources (a CLI socket today; an experimental
  read-only mirror of Apple's `usernoted` store behind a flag).
- **This repo owns the compositor and nothing else** — the daemon, its
  providers, the rules engine, the banner/inbox UI, the `trill` CLI. How trill
  is *launched* (launchd, login item, the CLI shim on PATH) belongs to the
  rice; its colors belong to `nebelung`; DND/Focus toggling is the rice's
  "Hush" and trill only deep-links there.
- **The compositor never blocks on — or trusts — a provider.** Each one is
  supervised in its own task, speaks only `NotificationEvent`, advertises
  health from an explicit `probe()`, and fails *closed into "off with a
  reason"* rather than into a broken pipeline.
- **System Mirror is quarantined.** Read-only, schema-probed, opt-in, disabled
  with a visible reason on drift — and no `usernoted` type or column name may
  appear outside `Providers/SystemMirror/`.
- **Trill reads Apple's notification settings; it never writes them.** Offering
  to open the pane and animate the clicks is the whole feature — don't add a
  "fix it for me". Read the group-container store macOS actually writes, never
  `com.apple.ncprefs` (a stale mirror that has cost this repo a shipped bug),
  check the allow-notifications bit before style or sound, and keep the third
  verdict: noisy, quiet, and *can't tell*.
- **The queue is the truth; panels are disposable.** Never park event state in
  a panel or a view — topology rebuilds re-render from `BannerQueue`.
- **No sound, ever. No notification content in logs. Never steal focus.**
- Decisions are pure: `PolicyEngine` reads (event, rules, clock) and touches no
  I/O; new delivery behavior goes through `DeliveryDecision`.
- **Versions are dates and CI owns them.** Cut with `bench release trill` from
  the workshop; the release workflow rewrites `nix/release.nix` and the
  Homebrew cask. Never hand-type a version or hand-bump a pin.

For review comments, the same bar applies as anywhere in the family:
correctness and boundaries (does this change belong in *this* repo?) over style.
