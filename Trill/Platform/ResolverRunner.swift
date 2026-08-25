import Foundation
import os.log

/// Runs one `ResolverPlan` and reports what it saw. The only place in trill
/// that starts a process or makes a network request, and it does neither
/// unless a plan says so — every decision was already made in `Resolver`.
///
/// What it deliberately does not do:
/// - **No shell.** `/usr/bin/env` gets the argv, so PATH lookup happens
///   without anything ever parsing a command *line*. There is no string a
///   quote could break out of.
/// - **No inherited environment.** The plan carries the whole of it. A GUI
///   daemon's environment is a grab bag of launchd leftovers, and a resolver
///   that only works because of one is a resolver that breaks on reboot.
/// - **No stderr, no output in logs.** A check's output can carry anything
///   the user's command prints; it decides a boolean and is dropped.
enum ResolverRunner {
    private static let log = Logger(subsystem: "com.hausfold.trill", category: "resolver")

    /// What one check saw. `failed` is not `notYet`: a resolver that can't
    /// run (no such program, a dead host) is broken, and the monitor gives up
    /// on it rather than repeating it for twelve hours.
    enum Outcome: Equatable, Sendable {
        case resolved
        case notYet
        case failed(String)
    }

    /// Most stdout is a word (`MERGED`). This is the ceiling before a
    /// misconfigured resolver streaming a log file becomes trill's problem.
    static let maxOutputBytes = 64 * 1024

    static func check(_ plan: ResolverPlan) async -> Outcome {
        switch plan {
        case .command(let argv, let env, let cwd, let timeout, let predicate):
            return await runCommand(argv: argv, env: env, cwd: cwd, timeout: timeout, predicate: predicate)
        case .request(let url, let timeout, let predicate):
            return await request(url: url, timeout: timeout, predicate: predicate)
        }
    }

    // MARK: - Command

    private static func runCommand(
        argv: [String],
        env: [String: String],
        cwd: String?,
        timeout: TimeInterval,
        predicate: RuleSet.Resolver.Predicate
    ) async -> Outcome {
        await withCheckedContinuation { continuation in
            // A blocking global-queue thread rather than async file handles:
            // this is three syscalls and a wait, and the cooperative pool is
            // the one place it must not happen.
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                // env, not the program directly: it resolves the program on
                // PATH the way a login shell would, without being a shell.
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = argv
                process.environment = env
                process.currentDirectoryURL = URL(
                    fileURLWithPath: cwd ?? NSHomeDirectory(), isDirectory: true
                )

                let output = Pipe()
                process.standardOutput = output
                // Dropped, not captured: a resolver's diagnostics are the
                // user's to read in their own terminal, and this process
                // logs no notification-adjacent content.
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    return continuation.resume(returning: .failed("cannot run \(argv.first ?? "?")"))
                }

                // The watchdog. `terminate` first so a well-behaved program
                // can clean up, SIGKILL a beat later for one that won't.
                // Only the direct child is signalled — a resolver that
                // daemonizes a grandchild holding the pipe open is a resolver
                // written wrong, and the read below is what would notice.
                let timedOut = Timeout()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    timedOut.fire()
                    process.terminate()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }

                let data = (try? output.fileHandleForReading.readToEnd()) ?? Data()
                process.waitUntilExit()

                if timedOut.didFire {
                    return continuation.resume(returning: .failed("timed out after \(Int(timeout))s"))
                }
                let status = process.terminationStatus
                // `env` answers 127 for "no such program" and 126 for "can't
                // execute it" — a broken resolver, not an unanswered
                // question. Left as a plain non-zero exit it would read as
                // "not yet" and poll a typo for twelve hours. A user whose
                // program genuinely exits 126/127 says so in `resolveWhen`,
                // and that wins.
                if predicate.exit != status, status == 126 || status == 127 {
                    return continuation.resume(returning: .failed(
                        "\(argv.first ?? "?") not found on PATH (\(env["PATH"] ?? ""))"
                    ))
                }
                let text = String(
                    decoding: data.prefix(maxOutputBytes), as: UTF8.self
                )
                let satisfied = predicate.satisfied(exit: status, stdout: text)
                continuation.resume(returning: satisfied ? .resolved : .notYet)
            }
        }
    }

    /// One bit, shared between the watchdog and the thread waiting on the
    /// process. A class so both see the same one; a lock because they are
    /// genuinely two threads.
    private final class Timeout: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func fire() { lock.lock(); fired = true; lock.unlock() }
        var didFire: Bool { lock.lock(); defer { lock.unlock() }; return fired }
    }

    // MARK: - Request

    private static func request(
        url: URL, timeout: TimeInterval, predicate: RuleSet.Resolver.Predicate
    ) async -> Outcome {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        // A resolver asks a question; it should not be able to *become* a
        // session. No cookies out, none kept, and nothing served from cache
        // — a cached 200 would resolve a question that is still open.
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("not an HTTP response")
            }
            let body = String(decoding: data.prefix(maxOutputBytes), as: UTF8.self)
            return predicate.satisfied(status: http.statusCode, body: body) ? .resolved : .notYet
        } catch {
            // Host down, DNS gone, TLS refused: the *check* failed, which is
            // not the same as the answer being no. The monitor counts these
            // and stops asking rather than retrying into a wall all day.
            return .failed("request failed")
        }
    }
}
