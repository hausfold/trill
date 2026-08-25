import Foundation

/// The scriptable face:
///
///   trill send --title "Deploy landed" [--body …] [--source deploy]
///              [--symbol checkmark.circle] [--thread deploys]
///              [--kind ask|fault|chat|pulse|done|note]
///              [--urgency low|normal|critical] [--redact] [--url https://…]
///              [--action "Label=https://…"] [--action "Label=lane:repo/name"]…
///   echo '{"title":"Backup complete"}' | trill send --json
///   trill ping
///
/// One JSON line out, one JSON line back, exit code says what happened:
/// 0 ok · 1 bad usage · 2 daemon unreachable · 3 daemon refused.
enum TrillCLI {
    static let subcommands: Set<String> = [
        "send", "ping", "doctor", "inbox", "resolve", "help", "--help", "-h",
    ]

    static func run(arguments: [String]) -> Int32 {
        switch arguments.first {
        case "ping":
            return roundTrip(SocketProvider.Request(v: 1, verb: "ping", event: nil))
        case "doctor":
            switch parseDoctor(Array(arguments.dropFirst())) {
            case .success(let invocation):
                return roundTrip(invocation.request) { response in
                    renderDoctor(response, json: invocation.json)
                }
            case .failure(let message):
                FileHandle.standardError.write(Data("trill: \(message)\n".utf8))
                return 1
            }
        case "inbox":
            switch parseInbox(Array(arguments.dropFirst())) {
            case .success(let request):
                return roundTrip(request)
            case .failure(let message):
                FileHandle.standardError.write(Data("trill: \(message)\n".utf8))
                return 1
            }
        case "resolve":
            switch parseResolve(Array(arguments.dropFirst())) {
            case .success(let request):
                // The count, like `send` prints the id: what the daemon
                // actually did. Zero is a success — the question had already
                // been answered by hand, which is the ending a poller wants.
                return roundTrip(request) { response in
                    print(response.cleared ?? 0)
                    return 0
                }
            case .failure(let message):
                FileHandle.standardError.write(Data("trill: \(message)\n".utf8))
                return 1
            }
        case "send":
            switch parseSend(Array(arguments.dropFirst())) {
            case .success(let event):
                return roundTrip(SocketProvider.Request(v: 1, verb: "send", event: event))
            case .failure(let message):
                FileHandle.standardError.write(Data("trill: \(message)\n".utf8))
                return 1
            }
        default:
            print(usage)
            return arguments.first.map { ["help", "--help", "-h"].contains($0) } == true ? 0 : 1
        }
    }

    // MARK: - Parsing

    enum ParseResult {
        case success(NotificationEvent)
        case failure(String)
    }

    static func parseSend(_ args: [String]) -> ParseResult {
        if args.contains("--json") {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard var event = try? JSONDecoder.trill.decode(NotificationEvent.self, from: data) else {
                return .failure("stdin was not a valid event JSON object")
            }
            if event.source.isEmpty { event.source = "cli" }
            return .success(event)
        }

        var title: String?
        var body: String?
        var subtitle: String?
        var source = "cli"
        var symbol: String?
        var thread: String?
        var key: String?
        var resolves: [String] = []
        var until: String?
        var kind: NotificationEvent.Kind?
        var urgency = NotificationEvent.Urgency.normal
        var privacy = NotificationEvent.Privacy.visible
        var actions: [NotificationEvent.Action] = []

        var iterator = args.makeIterator()
        while let flag = iterator.next() {
            func value() -> String? { iterator.next() }
            switch flag {
            case "--title": title = value()
            case "--body": body = value()
            case "--subtitle": subtitle = value()
            case "--source": source = value() ?? source
            case "--symbol": symbol = value()
            case "--thread": thread = value()
            case "--key": key = value()
            case "--resolves":
                guard let raw = value() else { return .failure("--resolves wants a key") }
                resolves.append(raw)
            case "--until":
                guard let raw = value() else {
                    return .failure("--until wants a resolver name from rules.json (NAME or NAME:arg,arg)")
                }
                until = raw
            case "--redact": privacy = .redacted
            case "--urgency":
                guard let raw = value(), let parsed = NotificationEvent.Urgency(rawValue: raw) else {
                    return .failure("--urgency wants low|normal|critical")
                }
                urgency = parsed
            case "--kind":
                guard let raw = value(), let parsed = NotificationEvent.Kind(rawValue: raw) else {
                    return .failure("--kind wants ask|fault|chat|pulse|done|note")
                }
                kind = parsed
            case "--url":
                guard let raw = value() else { return .failure("--url wants a value") }
                actions.append(.init(id: "url", label: "Open", kind: .openURL, target: raw))
            case "--action":
                // "Label=target": a web/file URL, app:BUNDLE.ID to activate
                // an app, or lane:REPO/LANE to go to a holt lane's window.
                // The label is what the pill says, so the `=` split takes the
                // *first* one — labels keep their own.
                guard let raw = value(), let eq = raw.firstIndex(of: "="),
                      eq != raw.startIndex, raw.index(after: eq) != raw.endIndex
                else {
                    return .failure("--action wants \"Label=https://…\", \"Label=app:bundle.id\" or \"Label=lane:repo/name\"")
                }
                let label = String(raw[..<eq])
                let target = String(raw[raw.index(after: eq)...])
                let action: NotificationEvent.Action
                if target.hasPrefix("app:") {
                    action = .init(id: "action-\(actions.count)", label: label, kind: .openApp, target: String(target.dropFirst(4)))
                } else if target.hasPrefix("lane:") {
                    let lane = String(target.dropFirst(5))
                    // Refused here as well as in the router, so a typo is a
                    // non-zero exit at the call site rather than a banner
                    // whose button silently does nothing.
                    guard NotificationEvent.Action.focusesLane(lane) else {
                        return .failure("--action lane: wants a lane name (letters, digits, . _ - /)")
                    }
                    action = .init(id: "action-\(actions.count)", label: label, kind: .focusLane, target: lane)
                } else if NotificationEvent.Action.opensAsURL(target) {
                    action = .init(id: "action-\(actions.count)", label: label, kind: .openURL, target: target)
                } else {
                    return .failure("--action target must be an http(s)/file URL, app:bundle.id or lane:repo/name")
                }
                actions.append(action)
            default:
                return .failure("unknown flag '\(flag)' (see `trill help`)")
            }
        }

        guard let title, !title.isEmpty else {
            return .failure("send requires --title (or --json on stdin)")
        }
        return .success(NotificationEvent(
            source: source, key: key, resolves: resolves, until: until,
            title: title, subtitle: subtitle, body: body,
            symbol: symbol, thread: thread,
            // Same inference the decoder applies to un-kinded events: an
            // unlabeled critical keeps its old red reading by being a fault.
            kind: kind ?? (urgency == .critical ? .fault : .note),
            urgency: urgency, privacy: privacy,
            actions: actions
        ))
    }

    // MARK: - inbox

    enum InboxParseResult: Equatable {
        case success(SocketProvider.Request)
        case failure(String)
    }

    /// `trill inbox [--asks]` — ask the daemon to open the inbox window,
    /// optionally filtered to `ask` events (the kind the ledge parks). The
    /// hook a hot corner or a keybind calls; the corner itself is haus's.
    static func parseInbox(_ args: [String]) -> InboxParseResult {
        var asks = false
        for arg in args {
            switch arg {
            case "--asks": asks = true
            default: return .failure("unknown flag '\(arg)' (see `trill help`)")
            }
        }
        return .success(SocketProvider.Request(
            v: 1, verb: "inbox", event: nil, asks: asks ? true : nil
        ))
    }

    // MARK: - resolve

    enum ResolveParseResult: Equatable {
        case success(SocketProvider.Request)
        case failure(String)
    }

    /// `trill resolve KEY [KEY …]` — the question was answered; take its
    /// banner or fin down. A KEY is either the id `trill send` printed or a
    /// `--key` the sender chose, which is the whole reason `--key` exists:
    /// the id is fine when the same script sends and resolves, and useless
    /// when the resolver is a different process entirely.
    ///
    /// Idempotent by design: resolving something already gone prints `0` and
    /// exits 0. A rebuild hook that fires twice is not an error.
    static func parseResolve(_ args: [String]) -> ResolveParseResult {
        var keys: [String] = []
        for arg in args {
            // No flags here, and a leading `-` is a typo worth catching:
            // silently resolving a fin named "--json" helps nobody.
            if arg.hasPrefix("-") { return .failure("unknown flag '\(arg)' (see `trill help`)") }
            keys.append(arg)
        }
        guard !keys.isEmpty else { return .failure("resolve wants at least one key (see `trill help`)") }
        return .success(SocketProvider.Request(v: 1, verb: "resolve", event: nil, keys: keys))
    }

    // MARK: - doctor

    /// The request to send, plus the one flag that never leaves this process:
    /// how to print the reply.
    struct DoctorInvocation: Equatable {
        var request: SocketProvider.Request
        var json: Bool
    }

    enum DoctorParseResult {
        case success(DoctorInvocation)
        case failure(String)
    }

    /// `trill doctor [--all] [--notify] [--json] [BUNDLE_ID …]`
    ///
    /// Bare, it audits the apps `rules.json` names — the daemon resolves that,
    /// so a rebuild hook can call this without knowing where rules live.
    static func parseDoctor(_ args: [String]) -> DoctorParseResult {
        var apps: [String] = []
        var all = false
        var notify = false
        var json = false

        for arg in args {
            switch arg {
            case "--all": all = true
            case "--notify": notify = true
            case "--json": json = true
            case let flag where flag.hasPrefix("-"):
                return .failure("unknown flag '\(flag)' (see `trill help`)")
            case let bundleID:
                apps.append(bundleID)
            }
        }

        return .success(DoctorInvocation(
            request: SocketProvider.Request(
                v: 1, verb: "doctor", event: nil,
                apps: apps.isEmpty ? nil : apps,
                all: all ? true : nil,
                notify: notify ? true : nil
            ),
            json: json
        ))
    }

    /// Human-readable by default, `--json` for anything scripting this.
    /// Exit code is the useful part for a rebuild hook: 0 = everything quiet,
    /// 4 = apps are still noisy, 5 = trill couldn't read macOS's settings.
    ///
    /// 5 exists because a hook that gates on this must be able to tell "quiet"
    /// from "blind". Silently exiting 0 when the store is unreadable would
    /// make every un-granted machine look clean.
    private static func renderDoctor(_ response: SocketProvider.Response, json: Bool) -> Int32 {
        if let unavailable = response.auditUnavailable {
            if json {
                // Encoded, not interpolated: one quote in the reason would
                // otherwise emit invalid JSON at the exact moment a script is
                // trying to find out what went wrong. Note this is an object
                // where success is an array — `jq` consumers should branch on
                // the exit code (5) before indexing.
                struct Unavailable: Encodable { let auditUnavailable: String }
                if let data = try? JSONEncoder.trill.encode(Unavailable(auditUnavailable: unavailable)),
                   let line = String(data: data, encoding: .utf8) {
                    print(line)
                }
            } else {
                print("trill doctor: can't tell — \(unavailable)")
                print("Grant it in System Settings → Privacy & Security → Full Disk Access.")
            }
            return 5
        }
        let findings = response.findings ?? []
        if json {
            let encoder = JSONEncoder.trill
            if let data = try? encoder.encode(findings), let line = String(data: data, encoding: .utf8) {
                print(line)
            }
            return findings.isEmpty ? 0 : 4
        }

        guard !findings.isEmpty else {
            print("trill doctor: no listed app is drawing its own banners.")
            return 0
        }

        print("trill doctor: \(findings.count) app(s) macOS still notifies for itself\n")
        for finding in findings {
            let desktop = finding.showsOnDesktop
                ? "on (\(finding.desktopAlert.rawValue))" : "off"
            print("  \(finding.bundleID)")
            print("      desktop: \(desktop)   sound: \(finding.playsSound ? "on" : "off")")
        }
        print("\nFix: System Settings → Notifications → <app> → untick Desktop, Play sound off.")
        print("Or run `trill doctor --notify` and click the banner to be walked through it.")
        return 4
    }

    // MARK: - Socket round trip

    /// `render` turns a successful reply into an exit code and whatever
    /// output that verb wants. Default: print the event id, exit 0 — what
    /// `send` and `ping` have always done.
    private static func roundTrip(
        _ request: SocketProvider.Request,
        render: (SocketProvider.Response) -> Int32 = { response in
            if let id = response.id { print(id) }
            return 0
        }
    ) -> Int32 {
        let path = SocketProvider.defaultSocketPath()
        guard let payload = try? JSONEncoder.trill.encode(request) else { return 1 }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return 2 }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let fits = withUnsafeMutableBytes(of: &addr.sun_path) { raw -> Bool in
            let bytes = Array(path.utf8)
            guard bytes.count < raw.count else { return false }
            raw.copyBytes(from: bytes)
            return true
        }
        guard fits else { return 2 }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard connected == 0 else {
            FileHandle.standardError.write(Data("trill: daemon not running (no socket at \(path))\n".utf8))
            return 2
        }

        var out = payload
        out.append(0x0A)
        let sent = out.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        guard sent else { return 2 }

        // Read one response line (the daemon answers promptly or not at all).
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !buffer.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { break }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > 64 * 1024 { break }
        }
        guard let nl = buffer.firstIndex(of: 0x0A),
              let response = try? JSONDecoder.trill.decode(
                  SocketProvider.Response.self, from: buffer.prefix(upTo: nl)
              )
        else { return 2 }

        if response.ok {
            return render(response)
        }
        FileHandle.standardError.write(Data("trill: \(response.error ?? "refused")\n".utf8))
        return 3
    }

    static let usage = """
    trill — a quiet, scriptable notification compositor for macOS

    usage:
      trill send --title TEXT [--body TEXT] [--subtitle TEXT] [--source NAME]
                 [--symbol SFNAME] [--thread NAME]
                 [--kind ask|fault|chat|pulse|done|note]
                 [--urgency low|normal|critical] [--redact] [--url URL]
                 [--action "Label=https://…"] [--action "Label=app:bundle.id"]
                 [--action "Label=lane:repo/name"]
                 [--key NAME] [--resolves KEY]… [--until RESOLVER[:args]]
      trill send --json          # full NotificationEvent JSON on stdin
      trill resolve KEY [KEY …]  # that question got answered — take it down
      trill ping                 # is the daemon up?
      trill doctor [--all] [--notify] [--json] [BUNDLE_ID …]
      trill inbox [--asks]       # open the inbox window (--asks: asks only)
      trill help

    --kind says what the event asks of the reader and colors the banner:
    ask (blocked on you) · fault (broke) · chat (a human) · pulse (in flight)
    · done (finished well) · note (fyi, the default). Unlabeled critical
    events render as fault. --urgency stays the loudness: low dims, critical
    bolds — still silent.

    An ask whose banner times out unattended doesn't vanish: it parks as a
    slim fin on the right screen edge until you answer or dismiss it. Hover
    the fin to slide the card back out. At most 5 park; older asks yield
    (they stay in the inbox — `trill inbox --asks` lists them). Fins survive
    a restart of the daemon; a fin nobody answers for a week is dropped.

    A parked question can also answer itself. Three ways, cheapest first:

      trill resolve <id>              # the id `trill send` printed
      trill send … --resolves KEY     # this event answers that question
      trill send … --key K --until R  # the daemon polls resolver R for you

    `--key` is optional and rarely needed: the printed id already names the
    event. Give one when *something else* has to name it later — a webhook,
    tomorrow's rebuild hook, a lane that respawned. Re-sending an ask with
    the same --key replaces its fin instead of growing a second one.

    `--until` names a resolver **declared in your rules.json** — never a
    command on this line. Anything local can talk to trill's socket, so the
    wire may only name what you already wrote down. See `resolvers` in
    ~/.config/trill/rules.json.

    --action adds a button (up to 3 drawn; the first is also what clicking
    the banner body does). --url is shorthand for --action "Open=URL".
    A lane: target goes to the window running that holt lane — it runs
    `holt focus <name>` and nothing else, and does nothing where holt
    isn't installed.

    doctor asks macOS which apps still draw their own banners or play their
    own sounds — the ones you'd otherwise see twice. With no arguments it
    checks the apps your rules.json names; --all checks every app on the Mac.
    --notify puts the findings on screen as banners you can click to be walked
    through the fix. trill never changes another app's settings itself.

    Those settings live in a TCC-protected container, so doctor needs Full
    Disk Access. Without it there is no answer to give and it says so (5)
    rather than exiting 0 while blind.

    exit codes: 0 ok · 1 bad usage · 2 daemon unreachable · 3 daemon refused
                4 doctor found apps still notifying natively
                5 doctor could not read macOS's settings (needs Full Disk Access)
    """
}
