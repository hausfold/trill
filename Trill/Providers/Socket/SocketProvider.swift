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
        /// "send" | "ping" | "doctor" | "inbox" | "resolve"
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

    init(
        path: String = SocketProvider.defaultSocketPath(),
        listedApps: @escaping @Sendable () -> [String] = { [] },
        openInbox: @escaping @Sendable (Bool) -> Void = { _ in },
        resolve: @escaping @Sendable ([String], @escaping @Sendable (Int) -> Void) -> Void = { _, done in done(0) }
    ) {
        self.path = path
        self.listedApps = listedApps
        self.openInbox = openInbox
        self.resolve = resolve
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

            let server = SocketServer(path: path) { line, reply in
                let response: Response
                switch Self.handle(line: line, decoder: decoder) {
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
        case ping
        case doctor(DoctorRequest)
        case inbox(asksOnly: Bool)
        case resolve([String])
        case failure(String)
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
