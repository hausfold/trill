import Foundation

/// The scriptable face:
///
///   trill send --title "Deploy landed" [--body …] [--source deploy]
///              [--symbol checkmark.circle] [--thread deploys]
///              [--urgency low|normal|critical] [--redact] [--url https://…]
///   echo '{"title":"Backup complete"}' | trill send --json
///   trill ping
///
/// One JSON line out, one JSON line back, exit code says what happened:
/// 0 ok · 1 bad usage · 2 daemon unreachable · 3 daemon refused.
enum TrillCLI {
    static let subcommands: Set<String> = ["send", "ping", "doctor", "help", "--help", "-h"]

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
            case "--redact": privacy = .redacted
            case "--urgency":
                guard let raw = value(), let parsed = NotificationEvent.Urgency(rawValue: raw) else {
                    return .failure("--urgency wants low|normal|critical")
                }
                urgency = parsed
            case "--url":
                guard let raw = value() else { return .failure("--url wants a value") }
                actions.append(.init(id: "url", label: "Open", kind: .openURL, target: raw))
            default:
                return .failure("unknown flag '\(flag)' (see `trill help`)")
            }
        }

        guard let title, !title.isEmpty else {
            return .failure("send requires --title (or --json on stdin)")
        }
        return .success(NotificationEvent(
            source: source, title: title, subtitle: subtitle, body: body,
            symbol: symbol, thread: thread, urgency: urgency, privacy: privacy,
            actions: actions
        ))
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
                 [--symbol SFNAME] [--thread NAME] [--urgency low|normal|critical]
                 [--redact] [--url URL]
      trill send --json          # full NotificationEvent JSON on stdin
      trill ping                 # is the daemon up?
      trill doctor [--all] [--notify] [--json] [BUNDLE_ID …]
      trill help

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
