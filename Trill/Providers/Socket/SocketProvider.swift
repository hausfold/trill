import Foundation

/// The scriptability backbone: `trill send …`, nix rebuild hooks, pounce
/// commands, any app — anything local — writes one JSON line to the socket and
/// gets one JSON line back. Wire format is versioned so old CLIs keep
/// working against newer daemons.
struct SocketProvider: NotificationProvider {
    let name = "socket"
    let capabilities = ProviderCapabilities(canOpenSource: false, canDismissAtSource: false)

    /// One JSON object per line. `v` is the wire version.
    struct Request: Codable, Equatable {
        var v: Int?
        /// "send" | "ask" | "ping" | "doctor" | "inbox" | "resolve" | "history"
        var verb: String
        var event: NotificationEvent?
        /// resolve: the ids or keys whose banners and fins are answered.
        var keys: [String]?
        /// doctor: audit exactly these bundle ids.
        var apps: [String]?
        /// doctor: audit every app macOS holds preferences for.
        var all: Bool?
        /// doctor: put the findings on screen as banners, not just in the reply.
        var notify: Bool?
        /// inbox: show only `ask` events — the kind the ledge parks. This is
        /// the deep link a hot corner (haus's wiring, not trill's) will call.
        var asks: Bool?
        /// ask: the buttons to draw, in order. The *daemon* turns these into
        /// actions, so the index a caller is told about is the index it asked
        /// for — a sender never mints a `reply` action itself.
        var pills: [String]?
        /// ask: seconds to wait before answering "nobody said". Absent means
        /// wait as long as the question stands — an ask parks on the ledge
        /// rather than expiring, so that is a real option.
        var timeout: Double?
        /// history: which rows to read back. One nested object rather than
        /// six loose keys, so the query the CLI parsed and the query the
        /// filter runs are the same value with nothing lost in between.
        var history: HistoryQuery?
    }

    struct Response: Codable {
        var ok: Bool
        var id: String?
        var error: String?
        /// doctor only. Optional, so a `send`/`ping` reply is byte-identical
        /// to what older CLIs already parse.
        var findings: [NativeNotificationSettings]?
        /// resolve only: how many banners/fins the keys actually took down.
        /// Zero is a success, not an error — resolving a question nobody is
        /// still asking is the normal ending for a `--until` poller that
        /// finished after the user had already answered by hand.
        var cleared: Int?
        /// doctor only. Set when the audit couldn't read macOS's settings at
        /// all — the reply then means "can't tell", and `findings` being empty
        /// says nothing. Optional so older CLIs keep parsing.
        var auditUnavailable: String?
        /// ask only: which pill was pressed, `nil` for every outcome that
        /// isn't an answer. This is the whole point of the verb — the one
        /// reply that is written long after the request arrived.
        var choice: Int?
        /// ask only: that pill's label, so a caller can read instead of count.
        var label: String?
        /// ask only: `answered` · `timeout` · `dismissed` · `canceled` ·
        /// `dropped` (see `AskBroker.Outcome`). Present even when `choice`
        /// isn't, because *why* nobody answered is the useful half.
        var outcome: String?
        /// history only: the rows that answered, newest first. Optional for
        /// the same reason `findings` is — an older CLI parses a `send` reply
        /// unchanged — and empty means *nothing matched*, which is a real
        /// answer here and not the absence of one.
        var history: [InboxEntry]?
        /// history only: how many rows the fetch looked at. The verb reads a
        /// bounded slice (`HistoryQuery.scanLimit`), so a caller that filled
        /// it has to be told the tail is out of view rather than left to read
        /// a short list as a complete one.
        var scanned: Int?
        /// history only, and the counterpart of `auditUnavailable`: set when
        /// there is no history to read at all — the user turned `persistHistory`
        /// off, so nothing was ever written. The reply then means "can't
        /// tell", and an empty `history` would be the lie: it would say
        /// "nothing fired" about a night trill never recorded.
        var historyUnavailable: String?
    }

    static func defaultSocketPath() -> String {
        AppPaths.supportDirectory.appendingPathComponent("trill.sock").path
    }

    private let path: String
    /// Resolves "a listed app" for a `doctor` request that didn't name any.
    /// Injected rather than read here so the provider keeps knowing nothing
    /// about rules — `AppRuntime` owns the hot-reloaded `RuleSet`.
    private let listedApps: @Sendable () -> [String]
    /// Opens the inbox window for the `inbox` verb. Injected for the same
    /// reason: the provider knows nothing about windows, and the CLI
    /// personality has none to open. The Bool is "asks only".
    private let openInbox: @Sendable (Bool) -> Void
    /// Takes down whatever answers to these keys and reports how many. Same
    /// injection reason again: the provider knows nothing about the queue,
    /// and the CLI personality has no queue to know about. Asynchronous
    /// because the answer lives on the main actor and the reply can wait —
    /// the socket writes back whenever the count arrives.
    private let resolve: @Sendable ([String], @escaping @Sendable (Int) -> Void) -> Void
    /// Reads stored history back for the `history` verb — the same injection
    /// reason a third time: the provider owns the wire, and trill's database
    /// belongs to `AppRuntime`. Asynchronous like `resolve` because the handle
    /// lives on the main actor.
    ///
    /// A `nil` page is "can't tell", not "nothing": history is a user switch,
    /// and the default here answers `nil` on purpose so a provider built
    /// without a store can never report an empty list as an empty night.
    private let history: @Sendable (HistoryQuery, @escaping @Sendable (HistoryPage?) -> Void) -> Void
    /// Where a blocked `trill ask` waits. Injected for the same reason as
    /// everything else here: the provider owns the wire, not the screen — it
    /// registers the caller and never learns what became of the banner.
    private let askBroker: AskBroker

    init(
        path: String = SocketProvider.defaultSocketPath(),
        listedApps: @escaping @Sendable () -> [String] = { [] },
        openInbox: @escaping @Sendable (Bool) -> Void = { _ in },
        resolve: @escaping @Sendable ([String], @escaping @Sendable (Int) -> Void) -> Void = { _, done in done(0) },
        history: @escaping @Sendable (HistoryQuery, @escaping @Sendable (HistoryPage?) -> Void) -> Void = { _, done in done(nil) },
        askBroker: AskBroker = AskBroker()
    ) {
        self.path = path
        self.listedApps = listedApps
        self.openInbox = openInbox
        self.resolve = resolve
        self.history = history
        self.askBroker = askBroker
    }

    func probe() async -> ProviderHealth {
        do {
            try FileManager.default.createDirectory(
                at: AppPaths.supportDirectory, withIntermediateDirectories: true
            )
            return .ready
        } catch {
            return .unavailable(reason: "cannot create \(AppPaths.supportDirectory.path)")
        }
    }

    func events() async -> AsyncStream<NotificationEvent> {
        AsyncStream { continuation in
            let decoder = JSONDecoder.trill
            let encoder = JSONEncoder.trill
            let listedApps = self.listedApps
            let openInbox = self.openInbox
            let resolve = self.resolve
            let history = self.history
            let askBroker = self.askBroker

            let server = SocketServer(path: path) { peer in
                // The caller hung up. Anything of theirs still on screen is a
                // question with nobody behind it — end it and take it down.
                askBroker.cancel(peer: peer)
            } onLine: { line, peer in
                let reply = peer.reply
                let response: Response
                switch Self.handle(line: line, decoder: decoder) {
                case .ask(let ask):
                    // The one verb that does not answer here. The caller stays
                    // blocked on the wire; the reply is written when a pill is
                    // pressed, the clock runs out, or the banner goes away.
                    askBroker.register(
                        id: ask.event.id, peer: peer.id,
                        labels: ask.labels, timeout: ask.timeout
                    ) { answer in
                        let done = Response(
                            ok: true, id: ask.event.id, error: nil,
                            choice: answer.choice, label: answer.label,
                            outcome: answer.outcome.rawValue
                        )
                        // A fresh encoder, like `resolve` below: this runs on
                        // whatever thread ends the ask, and JSONEncoder isn't
                        // Sendable.
                        reply((try? JSONEncoder.trill.encode(done)) ?? Data(#"{"ok":false}"#.utf8))
                    }
                    continuation.yield(ask.event)
                    return
                case .send(let event):
                    continuation.yield(event)
                    response = Response(ok: true, id: event.id, error: nil)
                case .ping:
                    response = Response(ok: true, id: nil, error: nil)
                case .doctor(let request):
                    // The *daemon* runs the audit, never the caller: a CLI
                    // that could hand us findings could hand us fabricated
                    // ones, and this reply is what pops banners.
                    let scope = request.scope ?? .only(listedApps())
                    if let findings = NotificationSettingsAudit.liveFindings(scope: scope) {
                        if request.notify {
                            for event in NotificationSettingsAudit.bannerEvents(for: findings) {
                                continuation.yield(event.normalized())
                            }
                        }
                        response = Response(ok: true, id: nil, error: nil, findings: findings)
                    } else {
                        // Couldn't read the store: answer "can't tell". Not an
                        // error — the daemon is fine, it just can't see — and
                        // emphatically not an empty findings list, which any
                        // caller would read as "all quiet".
                        response = Response(
                            ok: true, id: nil, error: nil, findings: nil,
                            auditUnavailable: NotificationSettingsAudit.unreadableReason()
                                ?? "macOS's notification settings are unreadable"
                        )
                    }
                case .inbox(let asksOnly):
                    // The caller *is* the summons: `trill inbox` is the user
                    // (or their hot corner) asking for a window, so opening
                    // one doesn't break the never-steal-focus rule.
                    openInbox(asksOnly)
                    response = Response(ok: true, id: nil, error: nil)
                case .resolve(let keys):
                    // The one verb that answers out of band: the queue lives
                    // on the main actor, so the count comes back later.
                    // `SocketServer` holds the connection until the peer
                    // closes it, so a deferred reply is exactly as safe as an
                    // inline one — and a `resolve` that replied before it
                    // resolved would be a lie a script could race.
                    resolve(keys) { cleared in
                        let answer = Response(ok: true, id: nil, error: nil, cleared: cleared)
                        // A fresh encoder rather than the captured one: this
                        // closure runs on whatever thread the main actor
                        // hands it back to, and JSONEncoder isn't Sendable.
                        reply((try? JSONEncoder.trill.encode(answer)) ?? Data(#"{"ok":false}"#.utf8))
                    }
                    return
                case .history(let query):
                    // Deferred like `resolve`, and for the same reason: the
                    // database handle lives on the main actor. `SocketServer`
                    // holds the connection until the peer closes it, so an
                    // out-of-band reply is exactly as safe as an inline one.
                    history(query) { page in
                        let answer: Response
                        if let page {
                            answer = Response(
                                ok: true, id: nil, error: nil,
                                history: page.entries, scanned: page.scanned
                            )
                        } else {
                            // Not an error and emphatically not an empty list:
                            // history is off, so there is nothing to have
                            // missed *and no way to know* whether anything
                            // did. Same three-verdict shape as `doctor`.
                            answer = Response(
                                ok: true, id: nil, error: nil,
                                historyUnavailable:
                                    "history is off — set \"persistHistory\": true in ~/.config/trill/config.json"
                            )
                        }
                        // A fresh encoder, like `resolve` and `ask` above:
                        // this runs on whatever thread the main actor hands
                        // it back to, and JSONEncoder isn't Sendable.
                        reply((try? JSONEncoder.trill.encode(answer)) ?? Data(#"{"ok":false}"#.utf8))
                    }
                    return
                case .failure(let message):
                    response = Response(ok: false, id: nil, error: message)
                }
                reply((try? encoder.encode(response)) ?? Data(#"{"ok":false}"#.utf8))
            }

            do {
                try server.start()
            } catch {
                // Finishing hands control to the supervisor: re-probe,
                // backoff, retry. The rest of the app never notices.
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in server.stop() }
        }
    }

    enum Handled: Equatable {
        case send(NotificationEvent)
        case ask(AskRequest)
        case ping
        case doctor(DoctorRequest)
        case inbox(asksOnly: Bool)
        case resolve([String])
        case history(HistoryQuery)
        case failure(String)
    }

    /// A parsed `ask` request: the event to put on screen, already wearing
    /// the pills as `reply` actions, plus what the answer indices mean and
    /// how long the caller will wait.
    ///
    /// The actions are minted *here*, not by the sender, and that is the
    /// point: the index the caller is eventually told is the index of the
    /// label it passed, in the order it passed them. A sender that could
    /// write its own `reply` targets could ship a banner whose Deny answers 0.
    struct AskRequest: Equatable, Sendable {
        var event: NotificationEvent
        var labels: [String]
        var timeout: TimeInterval?
    }

    /// A parsed `doctor` request: what to audit, and whether to say it out
    /// loud. Kept separate from the wire `Request` so the parse is testable.
    ///
    /// A nil `scope` means "whatever this daemon considers a listed app" —
    /// the caller declined to say, so the *daemon* answers it from its own
    /// hot-reloaded rules. That's deliberate: a rebuild hook running `trill
    /// doctor` shouldn't have to know where `rules.json` lives.
    struct DoctorRequest: Equatable, Sendable {
        var scope: NotificationSettingsAudit.Scope?
        var notify: Bool
    }

    /// Pure request handling, testable without a socket.
    static func handle(line: Data, decoder: JSONDecoder = .trill) -> Handled {
        let request: Request
        do {
            request = try decoder.decode(Request.self, from: line)
        } catch {
            return .failure("invalid JSON request")
        }
        switch request.verb {
        case "ping":
            return .ping
        case "send":
            guard let event = request.event else { return .failure("send requires an event") }
            guard !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure("event.title must not be empty")
            }
            return .send(event.normalized())
        case "ask":
            guard var event = request.event else { return .failure("ask requires an event") }
            guard !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure("event.title must not be empty")
            }
            let labels = (request.pills ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { String($0.prefix(NotificationEvent.Limits.pillLabel)) }
            guard !labels.isEmpty else {
                return .failure("ask requires at least one pill")
            }
            guard labels.count <= NotificationEvent.Limits.drawnActions else {
                return .failure("ask draws at most \(NotificationEvent.Limits.drawnActions) pills")
            }
            // The kind is not the caller's to choose: a question that can't
            // park on the ledge is a question that vanishes with nobody
            // blocked on it answered — and the ledge only holds asks.
            event.kind = .ask
            event.actions = labels.enumerated().map { index, label in
                .init(id: "ask-\(index)", label: label, kind: .reply, target: String(index))
            }
            // A thread would let two questions coalesce into one card, hiding
            // the pills of whichever lost the face while its caller kept
            // waiting. Asks stand alone.
            event.thread = nil
            return .ask(AskRequest(
                event: event.normalized(),
                labels: labels,
                timeout: request.timeout.flatMap { $0 > 0 ? $0 : nil }
            ))
        case "doctor":
            // An explicit app list always wins over `--all`; asking for both
            // is a caller being specific, not a caller being ambiguous.
            let named = (request.apps ?? []).filter { !$0.isEmpty }
            let scope: NotificationSettingsAudit.Scope?
            if !named.isEmpty {
                scope = .only(named)
            } else if request.all == true {
                scope = .everything
            } else {
                scope = nil // the daemon's own listed apps
            }
            return .doctor(DoctorRequest(scope: scope, notify: request.notify == true))
        case "inbox":
            return .inbox(asksOnly: request.asks == true)
        case "resolve":
            let keys = (request.keys ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !keys.isEmpty else { return .failure("resolve requires at least one key") }
            return .resolve(Array(keys.prefix(NotificationEvent.Limits.resolvedKeys)))
        case "history":
            // A missing query is the default one — `trill history` with no
            // flags is the common call, and an omitted object should mean the
            // same as an empty one. Clamped because the CLI is not the only
            // thing that can write to this socket.
            return .history((request.history ?? HistoryQuery()).clamped())
        case let other:
            return .failure("unknown verb '\(other)'")
        }
    }
}

enum AppPaths {
    /// A Debug build carries its own bundle id (`…trill.debug`) so it can't
    /// fight the installed app over one TCC row — see the note in
    /// `scripts/dev-install.sh`. Give it its own writable state too: a test
    /// run that boots the app would otherwise bind the *installed* daemon's
    /// socket and write its database, which is a second daemon answering
    /// `trill send` from a checkout nobody installed.
    private static var isDebugBuild: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".debug") == true
    }

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(isDebugBuild ? "Trill (debug)" : "Trill", isDirectory: true)
    }

    static var configDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/trill", isDirectory: true)
    }

    static var rulesFile: URL { configDirectory.appendingPathComponent("rules.json") }
    /// The app-level switches — the source of truth for everything in
    /// Settings. Shared with the installed app the way `rules.json` is: a
    /// Debug build gets its own *state*, not its own configuration.
    static var configFile: URL { configDirectory.appendingPathComponent("config.json") }
    static var databaseFile: URL { supportDirectory.appendingPathComponent("trill.db") }
}

extension JSONDecoder {
    static var trill: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

extension JSONEncoder {
    static var trill: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
}
