import Foundation

/// A declared way to find out whether a parked question has answered itself.
///
/// The whole design is one sentence: **the wire may name a resolver, never
/// describe one.** `trill send --until pr-merged:142,hausfold/trill` picks a
/// resolver out of `~/.config/trill/rules.json`; the command (or URL) behind
/// that name lives in a file only the user writes. Anything local can talk to
/// trill's socket, so the alternative — a command string on the wire — would
/// make the daemon a "run this for me on a timer" service for every process
/// on the Mac, in a GUI session that may hold Full Disk Access. This is also
/// the shape `RuleSet` already promised: "a future opt-in hook, never an
/// implicit shell-out per event".
///
/// Everything here is pure. Parsing an invocation, substituting arguments and
/// judging an outcome are decisions; running the thing is `ResolverRunner`'s
/// job, and it gets handed a `ResolverPlan` with nothing left to decide.
extension RuleSet {
    struct Resolver: Codable, Sendable, Equatable {
        /// argv — element 0 is the program, looked up on PATH. **Never a
        /// shell string**: there is no `sh -c` anywhere in this path, so
        /// quoting, globbing and `;` simply have no meaning, and an argument
        /// can't grow into a second command.
        var run: [String]?
        /// An http(s) URL to GET instead. Mutually exclusive with `run`.
        var get: String?
        /// What counts as "yes". Omitted means exit 0 for a command, 2xx for
        /// a request.
        var resolveWhen: Predicate?
        /// Extra environment for a command — where a token belongs if one is
        /// needed. It comes from the rules file, never from the wire.
        var env: [String: String]?
        /// Working directory for a command. Defaults to the user's home:
        /// the lane an ask came from may not exist any more, and a resolver
        /// that silently ran somewhere else would be worse than one that
        /// failed.
        var cwd: String?

        /// How often to check, how long one check may take, and when to stop
        /// asking. `giveUpAfter` is measured from the *event's* timestamp,
        /// not from when the poller armed, so restarting the daemon can't
        /// hand a question another twelve hours.
        var every: TimeInterval
        var timeout: TimeInterval
        var giveUpAfter: TimeInterval

        enum Defaults {
            static let every: TimeInterval = 120
            static let timeout: TimeInterval = 10
            static let giveUpAfter: TimeInterval = 12 * 3600
        }

        /// Floors and ceilings, applied on decode. A resolver is a background
        /// poller the user will forget they wrote; `every: 0.1` would be a
        /// fork bomb with a nice syntax, and a 3-day timeout would pin a
        /// process for the life of the daemon.
        enum Bounds {
            static let every: ClosedRange<TimeInterval> = 5...(24 * 3600)
            static let timeout: ClosedRange<TimeInterval> = 1...120
            static let giveUpAfter: ClosedRange<TimeInterval> = 60...(30 * 24 * 3600)
        }

        /// PATH for a command, when the resolver's own `env` doesn't set one.
        /// Spelled out because a GUI daemon inherits launchd's PATH, which
        /// has neither Homebrew nor anything the user installed — the single
        /// likeliest reason a resolver that works in a terminal wouldn't work
        /// here.
        static let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        /// What "yes" looks like. Every stated clause must hold — they are
        /// AND, not OR — so a check can't pass on a coincidence.
        struct Predicate: Codable, Sendable, Equatable {
            /// Exit status a command must have.
            var exit: Int32?
            /// Trimmed stdout, compared whole. `MERGED`, not `*MERGED*`.
            var stdout: String?
            /// Substring of stdout. Weaker than `stdout`; say what you mean.
            var stdoutContains: String?
            /// HTTP status a request must return.
            var status: Int?
            /// Substring of the response body.
            var bodyContains: String?

            var isEmpty: Bool {
                exit == nil && stdout == nil && stdoutContains == nil
                    && status == nil && bodyContains == nil
            }

            /// A command's verdict. With nothing stated, exit 0 is the answer
            /// — but the moment anything else is stated, the exit clause is
            /// only checked if it was *asked for*: `{"stdout": "MERGED"}`
            /// means the text, and a program that prints MERGED and exits 1
            /// is the program being odd, not the question being unanswered.
            func satisfied(exit code: Int32, stdout output: String) -> Bool {
                if isEmpty { return code == 0 }
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if let exit, exit != code { return false }
                if let stdout, stdout != trimmed { return false }
                if let stdoutContains, !trimmed.contains(stdoutContains) { return false }
                // A predicate that only talks about HTTP can never be
                // satisfied by a command; saying so beats passing by default.
                if status != nil || bodyContains != nil { return false }
                return true
            }

            /// A request's verdict. Nothing stated means any 2xx.
            func satisfied(status code: Int, body: String) -> Bool {
                if isEmpty { return (200..<300).contains(code) }
                if let status, status != code { return false }
                if let bodyContains, !body.contains(bodyContains) { return false }
                if exit != nil || stdout != nil || stdoutContains != nil { return false }
                return true
            }
        }

        // MARK: - Codable

        enum CodingKeys: String, CodingKey {
            case run, get, resolveWhen, env, cwd, every, timeout, giveUpAfter
        }

        init(
            run: [String]? = nil,
            get: String? = nil,
            resolveWhen: Predicate? = nil,
            env: [String: String]? = nil,
            cwd: String? = nil,
            every: TimeInterval = Defaults.every,
            timeout: TimeInterval = Defaults.timeout,
            giveUpAfter: TimeInterval = Defaults.giveUpAfter
        ) {
            self.run = run
            self.get = get
            self.resolveWhen = resolveWhen
            self.env = env
            self.cwd = cwd
            self.every = every.clamped(to: Bounds.every)
            self.timeout = timeout.clamped(to: Bounds.timeout)
            self.giveUpAfter = giveUpAfter.clamped(to: Bounds.giveUpAfter)
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                run: try c.decodeIfPresent([String].self, forKey: .run),
                get: try c.decodeIfPresent(String.self, forKey: .get),
                resolveWhen: try c.decodeIfPresent(Predicate.self, forKey: .resolveWhen),
                env: try c.decodeIfPresent([String: String].self, forKey: .env),
                cwd: try c.decodeIfPresent(String.self, forKey: .cwd),
                every: try Self.seconds(c, .every) ?? Defaults.every,
                timeout: try Self.seconds(c, .timeout) ?? Defaults.timeout,
                giveUpAfter: try Self.seconds(c, .giveUpAfter) ?? Defaults.giveUpAfter
            )
        }

        /// Durations are written the way a human writes them — `"2m"`,
        /// `"10s"`, `"12h"`, `"3d"` — or as bare seconds. Encoding always
        /// emits seconds; this file is read far more often than it's written
        /// by a machine.
        static func seconds(from text: String) -> TimeInterval? {
            let raw = text.trimmingCharacters(in: .whitespaces).lowercased()
            guard let unit = raw.last else { return nil }
            let multipliers: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
            guard let multiplier = multipliers[unit] else { return Double(raw) }
            guard let amount = Double(raw.dropLast()) else { return nil }
            return amount * multiplier
        }

        private static func seconds(
            _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
        ) throws -> TimeInterval? {
            if let number = try? container.decodeIfPresent(Double.self, forKey: key) { return number }
            guard let text = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
            guard let parsed = seconds(from: text) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: container,
                    debugDescription: "'\(text)' is not a duration (try 30s, 2m, 12h, 3d or a number of seconds)"
                )
            }
            return parsed
        }
    }
}

/// Why a resolver couldn't be built. A type rather than a bare `String`
/// because `Result` wants an `Error` — and a wrapper that reads as a string
/// at every call site keeps the messages written for the person editing
/// `rules.json`, which is the only audience they have.
struct ResolverProblem: Error, Equatable, CustomStringConvertible,
                        ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    var message: String

    init(_ message: String) { self.message = message }
    init(stringLiteral value: String) { self.message = value }
    init(stringInterpolation: DefaultStringInterpolation) {
        self.message = String(stringInterpolation: stringInterpolation)
    }

    var description: String { message }
}

/// `name` or `name:arg1,arg2` — what `--until` carries and all the wire ever
/// gets to say about a resolver.
struct ResolverInvocation: Equatable, Sendable {
    var name: String
    var args: [String]

    /// Args a single invocation may carry — `$1`…`$9`, and no more, because
    /// the substitution has one digit.
    static let maxArgs = 9
    static let maxArgLength = 200

    static func parse(_ raw: String) -> Result<ResolverInvocation, ResolverProblem> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure("empty resolver name") }

        let name: String
        var args: [String] = []
        if let colon = trimmed.firstIndex(of: ":") {
            name = String(trimmed[..<colon])
            let tail = String(trimmed[trimmed.index(after: colon)...])
            args = tail.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        } else {
            name = trimmed
        }

        guard !name.isEmpty else { return .failure("empty resolver name") }
        guard args.count <= maxArgs else { return .failure("a resolver takes at most \(maxArgs) arguments") }
        for arg in args {
            guard !arg.isEmpty else { return .failure("empty resolver argument") }
            guard arg.count <= maxArgLength else { return .failure("resolver argument too long") }
            // The flag-injection guard, and the same call `focusesLane` makes:
            // an argument that can start with `-` can turn `gh pr view $1`
            // into `gh pr view --repo something-else`. A resolver's arguments
            // are values — issue numbers, branch names, hosts — never flags.
            guard !arg.hasPrefix("-") else {
                return .failure("resolver arguments may not start with '-' (they are values, not flags)")
            }
            guard !arg.unicodeScalars.contains(where: { $0.properties.isDefaultIgnorableCodePoint || $0.value < 0x20 })
            else { return .failure("resolver argument contains control characters") }
        }
        return .success(ResolverInvocation(name: name, args: args))
    }
}

/// A resolver with its arguments already substituted in and its bounds
/// already applied: everything decided, nothing left to interpret. The runner
/// takes one of these and does exactly what it says.
enum ResolverPlan: Equatable, Sendable {
    case command(
        argv: [String],
        env: [String: String],
        cwd: String?,
        timeout: TimeInterval,
        predicate: RuleSet.Resolver.Predicate
    )
    case request(url: URL, timeout: TimeInterval, predicate: RuleSet.Resolver.Predicate)
}

extension RuleSet.Resolver {
    /// Build the plan, or say why there isn't one. Every refusal here is a
    /// line in the user's own rules file being wrong, so the messages name
    /// the file's vocabulary, not Swift's.
    func plan(arguments: [String]) -> Result<ResolverPlan, ResolverProblem> {
        switch (run, get) {
        case (nil, nil):
            return .failure("a resolver needs either \"run\" (argv) or \"get\" (a URL)")
        case (.some, .some):
            return .failure("a resolver takes \"run\" or \"get\", not both")
        case (.some(let argv), nil):
            guard let program = argv.first, !program.isEmpty else {
                return .failure("\"run\" must start with a program name")
            }
            guard !program.hasPrefix("-") else {
                return .failure("\"run\" must start with a program name, not a flag")
            }
            var substituted: [String] = []
            for element in argv {
                switch Self.substitute(element, arguments: arguments, encode: nil) {
                case .success(let value): substituted.append(value)
                case .failure(let message): return .failure(message)
                }
            }
            var environment = [
                "PATH": Self.defaultPath,
                "HOME": NSHomeDirectory(),
                // A resolver runs unattended: anything that would like to ask
                // a question should find no terminal to ask it on.
                "TERM": "dumb",
            ]
            for (key, value) in env ?? [:] { environment[key] = value }
            return .success(.command(
                argv: substituted, env: environment, cwd: cwd,
                timeout: timeout, predicate: resolveWhen ?? Predicate()
            ))
        case (nil, .some(let template)):
            let substituted: String
            switch Self.substitute(template, arguments: arguments, encode: Self.urlEncode) {
            case .success(let value): substituted = value
            case .failure(let message): return .failure(message)
            }
            guard let url = URL(string: substituted),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http"
            else { return .failure("\"get\" must be an http(s) URL") }
            return .success(.request(
                url: url, timeout: timeout, predicate: resolveWhen ?? Predicate()
            ))
        }
    }

    /// `$1`…`$9`, and nothing else. No environment expansion, no nesting, no
    /// `$@`: a resolver's template is a shape with holes in it, and the holes
    /// are numbered. A `$n` with no matching argument is an error rather than
    /// an empty string — `gh pr view ""` would happily do something.
    static func substitute(
        _ template: String, arguments: [String], encode: ((String) -> String)?
    ) -> Result<String, ResolverProblem> {
        var output = ""
        var rest = Substring(template)
        while let dollar = rest.firstIndex(of: "$") {
            output += rest[..<dollar]
            let afterDollar = rest.index(after: dollar)
            guard afterDollar < rest.endIndex,
                  let digit = rest[afterDollar].wholeNumberValue,
                  (1...ResolverInvocation.maxArgs).contains(digit)
            else {
                // A literal `$` that isn't a placeholder stays a literal `$`.
                output.append("$")
                rest = rest[afterDollar...]
                continue
            }
            guard digit <= arguments.count else {
                return .failure("this resolver wants $\(digit) but the invocation passed \(arguments.count) argument(s)")
            }
            let value = arguments[digit - 1]
            output += encode?(value) ?? value
            rest = rest[rest.index(after: afterDollar)...]
        }
        output += rest
        return .success(output)
    }

    /// Strict percent-encoding for a value going into a URL: only the
    /// unreserved set survives, so an argument can't open a query parameter,
    /// a path segment or a second host.
    static func urlEncode(_ value: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}

private extension TimeInterval {
    func clamped(to range: ClosedRange<TimeInterval>) -> TimeInterval {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
