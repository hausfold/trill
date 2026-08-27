import Foundation

/// The one event model every provider maps into and every surface renders
/// from. Provider-specific shapes (socket JSON, usernoted rows, future
/// webhook payloads) are translated at the provider boundary and never leak
/// past it.
struct NotificationEvent: Codable, Sendable, Identifiable, Equatable {
    enum Urgency: String, Codable, Sendable, Comparable {
        case low, normal, critical

        private var rank: Int {
            switch self {
            case .low: 0
            case .normal: 1
            case .critical: 2
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
    }

    /// How much of the event may be drawn on a shared screen. `redacted`
    /// banners show source + title only; the body stays inbox-only.
    enum Privacy: String, Codable, Sendable {
        case visible, redacted
    }

    /// What the event asks of the reader — a different axis than urgency
    /// (a `fault` can be minor; a `note` can be critical). Kind owns the
    /// banner's hue, urgency owns its weight; the two never fight because
    /// they color different things.
    enum Kind: String, Codable, Sendable, CaseIterable {
        /// Blocked on the user: a lane wanting permission, a review request.
        case ask
        /// Something broke or degraded.
        case fault
        /// A human wrote words at you.
        case chat
        /// A long-running thing, progressing.
        case pulse
        /// Something you were waiting on finished well.
        case done
        /// FYI — the default, the quiet backbone.
        case note

        /// Glyph drawn when the event carries no `symbol` of its own. Bare
        /// shapes, not `.circle` variants: the chip is already the container.
        var defaultSymbol: String {
            switch self {
            case .ask: "questionmark"
            case .fault: "exclamationmark.triangle.fill"
            case .chat: "bubble.left.fill"
            case .pulse: "arrow.triangle.2.circlepath"
            case .done: "checkmark"
            case .note: "info"
            }
        }
    }

    /// An action the *source* can honor. Providers advertise what they can
    /// actually do (the family's capability pattern); the renderer never invents
    /// buttons the source can't back.
    struct Action: Codable, Sendable, Equatable, Identifiable {
        enum Kind: String, Codable, Sendable {
            /// Activate the app the event came from.
            case openApp = "open_app"
            /// Open a URL carried in the event.
            case openURL = "open_url"
            /// Run a user-configured hook command (opt-in, rules-declared).
            case command
            /// Open the helper that walks the user through turning Apple's
            /// own banners off. `target` names the apps to walk: one bundle
            /// id, or several comma-joined when one banner stands for a whole
            /// worklist. A nil target names nothing, and the helper falls back
            /// to the apps `rules.json` lists — never to every app on the Mac.
            /// trill never writes those settings itself — this only opens
            /// System Settings and stands beside it.
            case silenceNative = "silence_native"
            /// Answer a blocking `trill ask`: `target` is the index of the
            /// pill, and pressing it is what makes that CLI exit. The one
            /// action kind whose effect is a line written back down the
            /// socket the event arrived on — see `AskBroker`. Inert when
            /// nobody is waiting any more, which is why a `reply` action is
            /// only ever minted by the daemon (`SocketProvider.handle`) and
            /// never by a sender.
            case reply
            /// Bring the terminal lane the event came from to the front.
            /// `target` names it the way scruff does — `<repo>/<lane>`, or a
            /// bare `<lane>` where that is unambiguous. trill knows nothing
            /// about windows or tilers; see `ActionRouter.focusLane`.
            case focusLane = "focus_lane"
            /// Open trill's own inbox, scoped by `target` — an `InboxScope`
            /// action target (`all`, `asks`, `digest:<name>@<epoch>`), or
            /// none for the plain window. What a digest card's click does:
            /// the card is a count, and this is the list behind it.
            case openInbox = "open_inbox"
            /// Show one calendar occurrence in Calendar.app. `target` is the
            /// occurrence's EventKit *external* identifier; the router builds
            /// the `ical://` URL itself, so the wire never carries a URL for
            /// this — same narrowness as `focus_lane`, and the reason it isn't
            /// just an `open_url`: a named capability keeps the list of things
            /// a banner click can reach short enough to say out loud.
            case openEvent = "open_event"
            /// An action kind this build has never heard of — a newer sender
            /// talking to an older trill. Inert by construction, and the
            /// reason an unknown kind costs the *action* rather than the
            /// whole event: scruff and trill update independently (trill is
            /// deliberately not a flake input), so version skew between them
            /// is the normal case, not the broken one.
            case unsupported

            init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Kind(rawValue: raw) ?? .unsupported
            }
        }

        var id: String
        var label: String
        var kind: Kind
        /// Kind-specific payload: a bundle id, a URL string, a hook name.
        var target: String?

        /// Schemes trill will hand to the workspace. Anything else is a
        /// refused click, so `hasDefaultAction` and `ActionRouter` both ask
        /// here rather than each keeping their own list.
        static let openableSchemes = ["https", "http", "file"]

        /// Would an `open_url` action with this target actually open?
        static func opensAsURL(_ target: String?) -> Bool {
            guard let target, let url = URL(string: target) else { return false }
            return openableSchemes.contains(url.scheme?.lowercased() ?? "")
        }

        /// Characters a lane name may contain. A whitelist rather than an
        /// escape: lane names are slugs scruff itself wrote (`<repo>/<lane>`),
        /// so anything outside this set is a bug in the sender and refusing
        /// it is the honest answer. It is also what keeps `ActionRouter`
        /// free of quoting questions — the name goes into an argv, never a
        /// shell, and a leading `-` is refused so it can't read as a flag.
        private static let laneCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/"
        )

        /// Which pill a `reply` action answers with, or nil if the target
        /// isn't one. Bounded by `Limits.drawnActions` because that is how
        /// many pills a card draws: an index past the last drawn one names a
        /// button nobody can press.
        static func replyChoice(_ target: String?) -> Int? {
            guard let target, let index = Int(target),
                  (0..<Limits.drawnActions).contains(index)
            else { return nil }
            return index
        }

        /// Would a `focus_lane` action with this target name a lane?
        static func focusesLane(_ target: String?) -> Bool {
            guard let target, !target.isEmpty, target.count <= 100,
                  !target.hasPrefix("-")
            else { return false }
            return target.unicodeScalars.allSatisfy(laneCharacters.contains)
        }

        /// Would an `open_event` action with this target name an occurrence?
        /// EventKit's external identifiers are opaque and provider-shaped
        /// (a CalDAV UID, an Exchange blob), so this can't be a whitelist the
        /// way lane names are — it only refuses what would break the URL the
        /// router builds. Everything else is percent-encoded into a path
        /// component there, never concatenated raw.
        static func namesCalendarEvent(_ target: String?) -> Bool {
            guard let target, !target.isEmpty, target.count <= 512 else { return false }
            return !target.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }

        /// Would `ActionRouter.perform` do something for this action? Every
        /// surface that draws an action asks *this* before drawing it as
        /// pressable — trill draws no dead buttons, so the pill row, the fold
        /// rows and the router all have to answer identically. A `command`
        /// action is not performable because hooks aren't wired yet (PRD M2)
        /// and the router only logs.
        var isPerformable: Bool {
            switch kind {
            case .openApp, .silenceNative: true
            case .openURL: Self.opensAsURL(target)
            case .focusLane: Self.focusesLane(target)
            case .openInbox: InboxScope(actionTarget: target) != nil
            case .reply: Self.replyChoice(target) != nil
            case .openEvent: Self.namesCalendarEvent(target)
            case .command, .unsupported: false
            }
        }
    }

    var id: String
    /// Short slug (`deploy`, `pounce`) or reverse-dns bundle id for mirrored
    /// system events (`com.tinyspeck.slackmacgap`).
    var source: String
    /// A name the sender chose so something *else* can name this event
    /// later — `trill resolve pr-142`. Optional, and usually absent:
    /// `resolutionKey` falls back to `id`, which `trill send` already prints,
    /// so a script that sends and later resolves needs no key at all. A key
    /// earns its keep only when the *resolver is a different process than the
    /// sender* — a webhook arriving as its own delivery with its own id, a
    /// rebuild hook clearing yesterday's ask, a lane that respawned. It is
    /// never drawn: the ledge shows a fin, not a name.
    var key: String?
    /// Keys (or ids) this event answers. Delivering it clears any banner,
    /// queued entry or parked fin naming one of them — the push half of
    /// resolution, and the reason the GitHub bridge can take a review-request
    /// fin down the moment the PR merges.
    var resolves: [String]
    /// A resolver *declared in `rules.json`*, invoked as `name` or
    /// `name:arg1,arg2`. The daemon polls it and resolves this event when it
    /// says yes — the pull half. The wire may only ever *name* a resolver:
    /// the command (or URL) itself lives in the user's own rules file, so a
    /// local process that can write to the socket still cannot make trill run
    /// something the user never wrote down.
    var until: String?
    var timestamp: Date

    var title: String
    var subtitle: String?
    var body: String?
    /// SF Symbol name for the banner glyph.
    var symbol: String?
    /// How far along a long-running thing is, `0…1`. Present means the card
    /// draws a bar; absent — the overwhelming case — means it doesn't, and
    /// there is deliberately no third state for "unknown": a bar that can't
    /// say how far along it is says nothing a `pulse` glyph doesn't already.
    ///
    /// A progress event is the one kind of arrival that isn't one. Paired
    /// with `key`, a tick *replaces* the card wearing that key rather than
    /// stacking beside it or folding into it — see `BannerQueue.enqueue` —
    /// so a build can report itself fifty times and own one card the whole
    /// way. Ticks are also not history: `EventRepository` keeps the endings,
    /// not the fifty steps to them.
    var progress: Double?

    /// Events sharing a thread coalesce under burst pressure.
    var thread: String?
    var kind: Kind
    var urgency: Urgency
    var privacy: Privacy

    var actions: [Action]
    var metadata: [String: String]

    init(
        id: String = UUID().uuidString,
        source: String,
        key: String? = nil,
        resolves: [String] = [],
        until: String? = nil,
        timestamp: Date = .now,
        title: String,
        subtitle: String? = nil,
        body: String? = nil,
        symbol: String? = nil,
        progress: Double? = nil,
        thread: String? = nil,
        kind: Kind = .note,
        urgency: Urgency = .normal,
        privacy: Privacy = .visible,
        actions: [Action] = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.source = source
        self.key = key
        self.resolves = resolves
        self.until = until
        self.timestamp = timestamp
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.symbol = symbol
        self.progress = progress
        self.thread = thread
        self.kind = kind
        self.urgency = urgency
        self.privacy = privacy
        self.actions = actions
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case id, source, key, resolves, until, timestamp, title, subtitle, body, symbol, progress,
             thread, kind, urgency, privacy, actions, metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.source = try container.decodeIfPresent(String.self, forKey: .source) ?? "cli"
        self.key = try container.decodeIfPresent(String.self, forKey: .key)
        self.resolves = try container.decodeIfPresent([String].self, forKey: .resolves) ?? []
        self.until = try container.decodeIfPresent(String.self, forKey: .until)
        self.timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? .now
        self.title = try container.decode(String.self, forKey: .title)
        self.subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        self.body = try container.decodeIfPresent(String.self, forKey: .body)
        self.symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        self.progress = try container.decodeIfPresent(Double.self, forKey: .progress)
        self.thread = try container.decodeIfPresent(String.self, forKey: .thread)
        self.urgency = try container.decodeIfPresent(Urgency.self, forKey: .urgency) ?? .normal
        // Events that predate `kind` (or senders that never learned it) keep
        // their old reading: critical used to render red, so an un-kinded
        // critical stays red by becoming a fault. Everything else is a note.
        self.kind = try container.decodeIfPresent(Kind.self, forKey: .kind)
            ?? (urgency == .critical ? .fault : .note)
        self.privacy = try container.decodeIfPresent(Privacy.self, forKey: .privacy) ?? .visible
        self.actions = try container.decodeIfPresent([Action].self, forKey: .actions) ?? []
        self.metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
    }
}

extension NotificationEvent {
    /// Does clicking this event do anything? Every surface that offers a
    /// click asks *this* before drawing itself as pressable, and
    /// `ActionRouter.performDefault` refuses the same set — trill draws no
    /// dead buttons, so the two have to answer identically.
    ///
    /// It mirrors `performDefault` exactly: the *first* declared action is the
    /// only one a click runs, so only that one is inspected. A `command`
    /// action is not pressable because hooks aren't wired yet (PRD M2) and the
    /// router only logs; a `open_url` whose target isn't a scheme the router
    /// will open is refused here for the same reason it is refused there.
    ///
    /// The one thing it can't promise is that a bundle id resolves to an
    /// installed app — that's a LaunchServices lookup, and this stays pure.
    /// A click on `source: "deploy.prod"` with no such app gets as far as the
    /// router and is logged there; the button is honest about intent, not
    /// about what's installed.
    var hasDefaultAction: Bool {
        guard let action = actions.first else { return source.contains(".") }
        // A question with more than one answer has no default one. The face
        // of an ask must never be a hidden "yes": a stray click on the title
        // of "Push to origin?" would otherwise press Allow.
        if action.kind == .reply, !pillActions.isEmpty { return false }
        return action.isPerformable
    }

    /// The actions the banner draws as its pill row: only when the event
    /// carries more than one (a single action rides the meta row as an inline
    /// label, and the card click *is* it), only the performable ones (no dead
    /// buttons), and at most `Limits.drawnActions` — the card is a glance,
    /// anything past three belongs to the inbox.
    var pillActions: [Action] {
        let performable = actions.filter(\.isPerformable)
        guard performable.count >= 2 else { return [] }
        return Array(performable.prefix(Limits.drawnActions))
    }

    /// A reading of something still running — a bar that hasn't reached the
    /// end. True on screen, but *not history*: fifty ticks are one build, and
    /// an inbox that listed each of them would bury the day's real events
    /// under one rebuild. So a tick is drawn and never stored, and never
    /// tallied into a digest either (a digest card whose click opened an
    /// empty list would be the same lie told twice) — the ending is what
    /// lands, because the ending is what you'd look for tomorrow.
    var isProgressTick: Bool {
        guard let progress else { return false }
        return progress < 1
    }

    /// What `trill resolve` and an incoming `resolves` list match against.
    /// The id is the fallback *and* the common case: an event needs no key
    /// to be resolvable, because `trill send` already printed one name for
    /// it. A key only adds a *second*, sender-chosen name — and matching
    /// accepts either, so both roads work.
    var resolutionKey: String { key ?? id }

    /// Names this event answers to. Order is irrelevant; both are matched.
    var resolutionNames: Set<String> { key.map { [id, $0] } ?? [id] }

    /// Field caps: a banner is a glance, not a document. Oversized input is
    /// truncated here, once, so no downstream surface needs its own limits.
    enum Limits {
        static let title = 200
        static let subtitle = 200
        static let body = 1000
        static let metadataPairs = 32
        /// Pills a banner will draw. More survive in the payload and inbox.
        static let drawnActions = 3
        /// Names one event may answer. A sender clearing a whole worklist at
        /// once is the reason this isn't 1; it being small is the reason a
        /// bug in a sender can't turn one delivery into a screen sweep.
        static let resolvedKeys = 16
        static let key = 200
        /// A pill is a word, not a sentence — it has to fit on a card next
        /// to two others. Enforced where `ask` pills are minted, so a long
        /// `--pill` is trimmed once rather than clipped by every surface.
        static let pillLabel = 24
    }

    /// Canonical form used for dedupe, persistence, and rendering.
    /// Whitespace-trimmed, length-capped, empty optionals dropped.
    func normalized() -> NotificationEvent {
        var event = self
        event.source = source.trimmed(cap: 100).lowercased()
        // Keys are matched literally and never displayed, so they're only
        // trimmed and capped — no case folding: `gh:hausfold/Trill#13` and
        // the sender's own slug both have to survive a round trip intact.
        event.key = key?.trimmed(cap: Limits.key).nonEmpty
        event.resolves = Array(
            resolves.compactMap { $0.trimmed(cap: Limits.key).nonEmpty }.prefix(Limits.resolvedKeys)
        )
        event.until = until?.trimmed(cap: Limits.key).nonEmpty
        event.title = title.trimmed(cap: Limits.title)
        event.subtitle = subtitle?.trimmed(cap: Limits.subtitle).nonEmpty
        event.body = body?.trimmed(cap: Limits.body).nonEmpty
        event.symbol = symbol?.trimmed(cap: 100).nonEmpty
        // Clamped once, here, so no surface has to defend itself against a
        // sender's 1.4 or a divide-by-zero NaN — a bar drawn from either is
        // a lie about a real build.
        event.progress = progress.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
        event.thread = thread?.trimmed(cap: 100).nonEmpty
        if event.metadata.count > Limits.metadataPairs {
            event.metadata = Dictionary(
                uniqueKeysWithValues: event.metadata.sorted { $0.key < $1.key }
                    .prefix(Limits.metadataPairs)
                    .map { ($0.key, $0.value) }
            )
        }
        return event
    }
}

private extension String {
    func trimmed(cap: Int) -> String {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > cap ? String(t.prefix(cap)) : t
    }

    var nonEmpty: String? { isEmpty ? nil : self }
}
