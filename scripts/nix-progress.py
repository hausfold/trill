#!/usr/bin/env python3
"""Turn nix's internal-json log stream into one trill card that fills up.

Driven by `nix-progress.sh` — see that file for the why and the usage. This
half does two things and no more: it re-renders the stream as the plain text
you'd have seen anyway, and it ticks a keyed `trill send --progress` as nix's
own counters move.

The counters are nix's, not ours: `resSetExpected` says how many builds and
fetches it thinks are left, and each activity's `stop` is one of them done.
That means the bar can move *backwards* when evaluation discovers more work —
which is the truth, and better than a bar that only ever lies upward.
"""

import json
import os
import subprocess
import sys
import threading
import time

# nix's activity types (src/libutil/logging.hh) — the two that stand for a
# whole set rather than one path. Their `resProgress` results are the same
# numbers nix's own bar prints as "3/17 built · 5/9 fetched": [done, expected,
# running, failed]. Measured against a real `nix build` stream, 2026-08-25.
#
# The per-path activities (actCopyPath 100, actFileTransfer 101) report the
# same result type in *bytes*, not paths, which is the trap here: summing
# those into a count gives 1/54568 and a bar that never moves. Read the set,
# not the members.
ACT_COPY_PATHS = 103
ACT_BUILDS = 104

# nix's result types.
RES_BUILD_LOG_LINE = 101
RES_SET_PHASE = 104
RES_PROGRESS = 105

TRILL = os.environ.get("TRILL_BIN_RESOLVED", "trill")
KEY = os.environ.get("TRILL_PROGRESS_KEY", "nix")
TITLE = os.environ.get("TRILL_PROGRESS_TITLE", "nix build")
SOURCE = os.environ.get("TRILL_PROGRESS_SOURCE", "nix")
# Per-derivation build logs, the way `nix build -L` shows them. Off by
# default for the same reason nix's own bar hides them.
VERBOSE = os.environ.get("TRILL_PROGRESS_VERBOSE") == "1"

# No card more often than this, however fast nix talks: every tick is a
# process launch, and a bar nobody can read moving is not worth one.
MIN_INTERVAL = 0.7

# …and no *less* often than this while the build runs. A banner's dismiss
# clock is short by design, and a big derivation can compile for minutes
# without moving a counter — so the card would expire mid-build and a later
# tick would draw a second one. Re-sending the same reading rearms that clock,
# which keeps "one card for the whole build" true without teaching the
# compositor about builds: a driver that dies stops beating, and its card
# leaves the screen on its own, which is exactly what should happen.
HEARTBEAT = 3.0


class Counters:
    """What nix says it has done and has left, in paths — never in bytes."""

    def __init__(self):
        self.types = {}                            # activity id -> its type
        self.sets = {ACT_BUILDS: (0, 0), ACT_COPY_PATHS: (0, 0)}
        self.phase = None

    def start(self, message):
        self.types[message.get("id")] = message.get("type", 0)

    def stop(self, message):
        self.types.pop(message.get("id"), None)

    def result(self, message):
        kind = message.get("type")
        fields = message.get("fields") or []
        if kind == RES_SET_PHASE and fields:
            self.phase = fields[0]
            return
        if kind != RES_PROGRESS or len(fields) < 2:
            return
        which = self.types.get(message.get("id"))
        if which not in self.sets:
            return
        done, expected = fields[0], fields[1]
        known_done, known_expected = self.sets[which]
        # nix zeroes a set when it empties — the last thing the build set
        # says after a path turns out to be substitutable is [0, 0]. That is
        # "nothing left here", not "nothing known yet", so the set leaves the
        # sum rather than freezing at 0/1 and pinning the bar at half.
        if expected == 0 and known_expected > 0:
            self.sets[which] = (0, 0)
            return
        self.sets[which] = (max(done, known_done), max(expected, known_expected))

    @property
    def fraction(self):
        done = sum(pair[0] for pair in self.sets.values())
        expected = sum(pair[1] for pair in self.sets.values())
        if expected == 0:
            return None
        # Never 1.0 while the process is still alive — the ending card is the
        # only thing allowed to say done.
        return min(done / expected, 0.99)

    @property
    def body(self):
        parts = []
        built, builds = self.sets[ACT_BUILDS]
        if builds:
            parts.append(f"{built}/{builds} built")
        fetched, fetches = self.sets[ACT_COPY_PATHS]
        if fetches:
            parts.append(f"{fetched}/{fetches} fetched")
        if self.phase:
            parts.append(self.phase)
        return " · ".join(parts) or "starting"


class Card:
    """The one card, and the only thing here that talks to trill.

    The reader keeps `latest` current and the heartbeat keeps the card alive;
    both go out through `flush`, so the lock is what stops two `trill send`s
    racing into the same key.
    """

    def __init__(self):
        self.lock = threading.Lock()
        self.latest = (0.0, "starting")
        self.sent = None
        self.sent_at = 0.0

    def update(self, fraction, body):
        self.latest = (fraction, body)
        self.flush()

    def flush(self, force=False):
        with self.lock:
            now = time.monotonic()
            fraction, body = self.latest
            state = (round(fraction, 2), body)
            if not force:
                # Rate limit first — every tick is a process launch, and a bar
                # nobody can watch move is not worth one.
                if now - self.sent_at < MIN_INTERVAL:
                    return
                # Nothing new to say, and the card isn't old enough to need
                # its clock rearmed.
                if state == self.sent and now - self.sent_at < HEARTBEAT:
                    return
            self.sent, self.sent_at = state, now
        argv = [
            TRILL, "send", "--key", KEY, "--source", SOURCE,
            "--title", TITLE, "--body", body, "--progress", f"{fraction:.4f}",
        ]
        try:
            subprocess.run(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        except OSError:
            # No daemon, no trill, no matter: this wrapper's job is to run the
            # build. A missing banner never fails one.
            pass

    def beat(self, stopping):
        while not stopping.wait(HEARTBEAT / 2):
            self.flush()


def main():
    counters = Counters()
    card = Card()
    card.flush(force=True)
    stopping = threading.Event()
    threading.Thread(target=card.beat, args=(stopping,), daemon=True).start()

    for line in sys.stdin:
        if not line.startswith("@nix "):
            sys.stdout.write(line)
            sys.stdout.flush()
            continue
        try:
            message = json.loads(line[5:])
        except json.JSONDecodeError:
            continue

        action = message.get("action")
        if action == "start":
            counters.start(message)
            text = message.get("text")
            if VERBOSE and text:
                print(text, flush=True)
        elif action == "stop":
            counters.stop(message)
        elif action == "result":
            counters.result(message)
            if VERBOSE and message.get("type") == RES_BUILD_LOG_LINE:
                fields = message.get("fields") or []
                if fields:
                    print(fields[0], flush=True)
        elif action == "msg":
            text = message.get("msg")
            if text:
                print(text, file=sys.stderr, flush=True)

        fraction = counters.fraction
        if fraction is not None:
            card.update(fraction, counters.body)

    stopping.set()


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass
