import Foundation
import os.log

/// **GitHub bridge.** GitHub → tunnel (cloudflared, haus's wiring) →
/// 127.0.0.1 → this provider. Webhooks, not polling, because latency is the
/// point: a review request should park on the Ledge seconds after it's made.
///
/// The trust story is deliberately small:
///   - trill holds no GitHub token and **never writes GitHub state** — the
///     receiver's whole auth is the webhook's HMAC secret, and a delivery
///     that doesn't verify is a 401, not an event;
///   - payload shapes stop at `GitHubWebhookMapper`; ids, event names, and
///     repo slugs are the only things that may reach a log line;
///   - a missing config, taken port, or flipped-off toggle is "off with a
///     reason" in Settings, never a broken pipeline.
struct GitHubWebhookProvider: NotificationProvider {
    let name = "github"
    let capabilities = ProviderCapabilities(canOpenSource: false, canDismissAtSource: false)

    private let configFile: URL
    /// Read from the config file's store, not `AppSettings`: the supervisor
    /// calls this off the main actor, and the toggle's only job here is
    /// yes/no.
    private let enabled: @Sendable () -> Bool

    private static let log = Logger(subsystem: "com.hausfold.trill", category: "github")

    init(
        configFile: URL = GitHubBridgeConfig.file,
        enabled: @escaping @Sendable () -> Bool = { true }
    ) {
        self.configFile = configFile
        self.enabled = enabled
    }

    func probe() async -> ProviderHealth {
        guard enabled() else { return .unavailable(reason: "switched off in Settings") }
        let config: GitHubBridgeConfig
        do {
            config = try GitHubBridgeConfig.load(from: configFile)
        } catch {
            return .unavailable(reason: "\(error)")
        }
        let port = config.port ?? GitHubBridgeConfig.defaultPort
        guard WebhookHTTPServer.portAvailable(port) else {
            return .unavailable(reason: "port \(port) is taken — is another trill running?")
        }
        return .ready
    }

    func events() async -> AsyncStream<NotificationEvent> {
        AsyncStream { continuation in
            guard enabled(), let config = try? GitHubBridgeConfig.load(from: configFile) else {
                continuation.finish()
                return
            }

            let server = WebhookHTTPServer(port: config.port ?? GitHubBridgeConfig.defaultPort) { request in
                Self.handle(request, config: config) { continuation.yield($0) }
            }
            do {
                try server.start()
            } catch {
                // Finishing hands control to the supervisor: re-probe,
                // backoff, and a reason in Settings if the port stays taken.
                continuation.finish()
                return
            }

            // The supervisor only re-probes after the stream ends, so the
            // Settings toggle needs a watcher: flipped off, the server stops
            // and the next probe reports "switched off" honestly.
            let toggleWatcher = Task { [enabled] in
                while !Task.isCancelled, enabled() {
                    try? await Task.sleep(for: .seconds(5))
                }
                server.stop()
                continuation.finish()
            }
            continuation.onTermination = { _ in
                toggleWatcher.cancel()
                server.stop()
            }
        }
    }

    /// One delivery in, one status out. Static and injected-yield so tests
    /// exercise the accept/reject seam without a socket.
    static func handle(
        _ request: HTTPRequest,
        config: GitHubBridgeConfig,
        yield: (NotificationEvent) -> Void
    ) -> Int {
        guard request.method == "POST" else { return 405 }
        guard GitHubWebhookMapper.validSignature(
            header: request.headers["x-hub-signature-256"],
            body: request.body,
            secret: config.secret
        ) else {
            // The tunnel hostname is public; unsigned traffic reaching it is
            // expected background noise, not an incident.
            log.info("rejected delivery: bad or missing signature")
            return 401
        }
        guard let eventName = request.headers["x-github-event"],
              let deliveryID = request.headers["x-github-delivery"] else { return 400 }

        if let event = GitHubWebhookMapper.event(
            name: eventName, deliveryID: deliveryID, payload: request.body, login: config.login
        ) {
            log.debug("delivery \(deliveryID, privacy: .public) (\(eventName, privacy: .public)) → \(event.kind.rawValue, privacy: .public)")
            yield(event.normalized())
        } else {
            log.debug("delivery \(deliveryID, privacy: .public) (\(eventName, privacy: .public)) ignored")
        }
        return 200
    }
}
