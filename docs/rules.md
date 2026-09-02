# Rules and settings — two files

**Exit 0 from `trill send` means the daemon *took* the event, not that a card
appeared.** A rule, a digest, quiet hours or a Focus may have sent it somewhere
better, and the two files below are where that was decided. (`trill ask` is the
exception: there the exit code is the pill pressed, and **75 means nobody
answered, which is never consent.**)

Everything trill decides is decided from two JSON files in
`~/.config/trill/`. Both are hot-reloaded on save, and Settings is a *view*
onto them: anything you can click you can type, and vice versa, without a
restart.

## `rules.json` — what gets through, and where

First matching rule wins. No match means banner.

```jsonc
{
  "rules": [
    { "match": { "source": "slack", "titleContains": "mentioned" }, "delivery": "banner" },
    { "match": { "source": "slack" }, "delivery": "digest", "digest": "work" },
    { "match": { "source": "ads" }, "delivery": "drop" },

    // …and *where* it draws. `primary` (the menu-bar display) is the default;
    // `builtin` and `external` are the hardware, `active` follows the pointer.
    // A rule that names only a display still banners — every target falls back
    // to `primary`, so unplugging a monitor moves its banners rather than
    // losing them.
    { "match": { "kind": "chat" }, "display": "builtin" },
    { "match": { "kind": "fault" }, "display": "active" }
  ],

  // Minutes since local midnight; may cross it. Non-critical events inside are
  // demoted to the inbox.
  "quietHours": { "startMinute": 1320, "endMinute": 420 },

  // What a *Focus* means, per kind. trill reads the Focus macOS is in — it
  // never turns one on or off. This block is the shipped default, so a file
  // that never mentions it behaves exactly like this: chatter stops
  // interrupting, faults still land, and a question parks on the ledge as a fin
  // instead of being swallowed (somebody is blocked on the answer). Name one
  // kind and the rest keep their defaults. `critical` punches through
  // regardless, the way it does through quiet hours — and quiet hours have the
  // last word over all of it.
  "focus": { "default": "inbox", "fault": "banner", "ask": "ledge" },

  // What `--until NAME` may name. The command lives here, in your file — never
  // on the wire, because anything local can talk to trill's socket. argv, not a
  // command line: there is no shell in this path, and wire arguments only reach
  // numbered holes ($1…$9).
  "resolvers": {
    "pr-merged": {
      "run": ["gh", "pr", "view", "$1", "--repo", "$2", "--json", "state", "-q", ".state"],
      "resolveWhen": { "stdout": "MERGED" },
      "every": "2m", "timeout": "10s", "giveUpAfter": "12h"
    },
    "endpoint-up": { "get": "https://$1/healthz", "resolveWhen": { "status": 200 } }
  }
}
```

`match` takes `source` (exact, case-insensitive — a sender's slug, or a bundle
id like `com.apple.MobileSMS` for anything System Mirror redrew),
`titleContains`, `urgencyAtMost` and `kind`. `delivery` — `banner`, `inbox`,
`digest` (with a sibling `digest` name) or `drop` — goes **flat beside**
`match`, never nested in it.

A `digest` rule banners nothing: it tallies, and draws one card on the hour —
*9 quiet things · ci ×4, garden ×3* — that opens the inbox on exactly those
events.

## `config.json` — the app's own switches

The source of truth for every app-level switch; Settings reads and writes this
same file. Every key is optional, and a key the file doesn't name is that key at
its default:

```json
{
  "launchAtLogin": true, "persistHistory": true,
  "systemMirror": false, "githubBridge": false, "calendar": false,
  "calendarLeadMinutes": 10,
  "shyWhenWatched": true, "catchUpCard": true, "focusAware": true,
  "cliLink": true
}
```

`persistHistory` is the one switch a *verb* answers for: with it off, nothing is
written down, so `trill history` says "can't tell" and exits 5 rather than
reporting an empty list as a quiet night. Same for the inbox window, which
empties the moment you switch it off.

`systemMirrorApps` is the one key with no default, because its *absence* is
itself a value: absent, the mirror draws every app it sees; a list means exactly
those; `[]` means none. See [other apps' notifications](other-apps.md).

Keys trill doesn't know are preserved verbatim across writes.

**If the file is a symlink into the Nix store**, trill refuses to write it and
says so rather than moving a switch a rebuild would revert — your desktop
generated that file, and the click wouldn't stick.
