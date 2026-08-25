import CryptoKit
import Foundation

/// `~/.config/trill/github.json` — everything the GitHub bridge needs, in one
/// owner-read file. `secret` is the webhook's HMAC secret (the receiver's
/// whole auth story — trill holds no GitHub token and can't call the API);
/// `login` is whose mentions and review requests count as "for me"; `port` is
/// where the tunnel's local leg points, defaulting so haus and trill agree
/// without either asking.
struct GitHubBridgeConfig: Codable, Sendable, Equatable {
    var secret: String
    var login: String
    var port: UInt16?

    static let defaultPort: UInt16 = 42787
    static var file: URL { AppPaths.configDirectory.appendingPathComponent("github.json") }

    /// Throws messages fit for `ProviderHealth.unavailable` — they tell the
    /// user what to create, not what call failed.
    static func load(from url: URL = file) throws -> GitHubBridgeConfig {
        guard let data = try? Data(contentsOf: url) else {
            throw SocketError(#"no \#(url.path) — write {"secret":"…","login":"…"} to connect GitHub"#)
        }
        let config: GitHubBridgeConfig
        do {
            config = try JSONDecoder().decode(GitHubBridgeConfig.self, from: data)
        } catch {
            throw SocketError("\(url.path) is not valid JSON for {secret, login, port?}")
        }
        guard !config.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !config.login.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SocketError("\(url.path) needs non-empty \"secret\" and \"login\"")
        }
        return config
    }
}

/// Turns raw GitHub webhook deliveries into `NotificationEvent`s. Pure —
/// (event name, delivery id, payload, login) in, event or nil out — so every
/// mapping rule is testable headless.
///
/// Quarantine: GitHub's payload shapes stop at this file. Nothing outside
/// `Providers/GitHub/` may name a webhook field, and unrecognized events map
/// to nil, never to a guess.
enum GitHubWebhookMapper {
    /// GitHub signs the raw body as `sha256=<hex>` in `X-Hub-Signature-256`.
    /// Constant-time compare: a webhook endpoint's rejection timing shouldn't
    /// narrate how close a forgery got.
    static func validSignature(header: String?, body: Data, secret: String) -> Bool {
        guard let header else { return false }
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8)))
        let expected = "sha256=" + mac.map { String(format: "%02x", $0) }.joined()
        let a = Array(expected.utf8), b = Array(header.lowercased().utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// The event→kind heart of the bridge: a review request is an `ask` (it
    /// parks on the Ledge), a red run is a `fault`, a green one is `done`, a
    /// mention is `chat`. Everything else is nil — the bridge banners what the
    /// kinds can say honestly and stays silent otherwise.
    static func event(name: String, deliveryID: String, payload: Data, login: String) -> NotificationEvent? {
        switch name {
        case "ping":
            return pingEvent(deliveryID: deliveryID, payload: payload)
        case "workflow_run":
            return workflowRunEvent(deliveryID: deliveryID, payload: payload)
        case "pull_request":
            return pullRequestEvent(deliveryID: deliveryID, payload: payload, login: login)
        case "issue_comment", "pull_request_review_comment":
            return mentionEvent(deliveryID: deliveryID, payload: payload, login: login)
        default:
            return nil
        }
    }

    // MARK: - Per-event mapping

    /// GitHub sends `ping` once when the hook is created — the one moment
    /// setup feedback is worth a banner.
    private static func pingEvent(deliveryID: String, payload: Data) -> NotificationEvent? {
        let ping = try? decoder.decode(PingPayload.self, from: payload)
        let scope = ping?.repository?.fullName ?? ping?.organization?.login
        return NotificationEvent(
            id: id(deliveryID),
            source: "github",
            title: "GitHub bridge connected",
            subtitle: scope.map { "webhook live for \($0)" },
            kind: .note,
            metadata: metadata(event: "ping", repo: scope)
        )
    }

    private static func workflowRunEvent(deliveryID: String, payload: Data) -> NotificationEvent? {
        guard let p = try? decoder.decode(WorkflowRunPayload.self, from: payload),
              p.action == "completed" else { return nil }
        let runName = p.workflowRun.name ?? "workflow"

        let kind: NotificationEvent.Kind
        let verdict: String
        switch p.workflowRun.conclusion {
        case "success":
            (kind, verdict) = (.done, "passed")
        case "failure", "startup_failure":
            (kind, verdict) = (.fault, "failed")
        case "timed_out":
            (kind, verdict) = (.fault, "timed out")
        case "action_required":
            // A run waiting on a human is literally what `ask` means.
            (kind, verdict) = (.ask, "needs approval")
        default:
            // cancelled / skipped / stale / neutral: somebody meant that, or
            // nothing happened — neither is worth a banner.
            return nil
        }

        return NotificationEvent(
            id: id(deliveryID),
            source: "github",
            title: "\(runName) \(verdict)",
            subtitle: [p.repository.fullName, p.workflowRun.headBranch].compactMap(\.self).joined(separator: " · "),
            body: p.workflowRun.displayTitle,
            thread: "gh-ci:\(p.repository.fullName):\(runName)",
            kind: kind,
            actions: [openAction(label: "Open run", url: p.workflowRun.htmlUrl)],
            metadata: metadata(event: "workflow_run", repo: p.repository.fullName)
        )
    }

    /// The PR lifecycle. Opened/reopened/closed are deliberately NOT filtered
    /// by actor: in this house PRs are opened by agent lanes running as the
    /// user, so "your own" PR opening is exactly the signal worth a banner.
    private static func pullRequestEvent(deliveryID: String, payload: Data, login: String) -> NotificationEvent? {
        guard let p = try? decoder.decode(PullRequestPayload.self, from: payload) else { return nil }

        let kind: NotificationEvent.Kind
        let verdict: String
        switch p.action {
        case "review_requested":
            // Requests aimed at a teammate (or a team) are theirs to hear.
            guard p.requestedReviewer?.login.caseInsensitiveCompare(login) == .orderedSame
            else { return nil }
            (kind, verdict) = (.ask, "Review requested")
        case "opened":
            (kind, verdict) = (.note, "PR opened")
        case "reopened":
            (kind, verdict) = (.note, "PR reopened")
        case "closed" where p.pullRequest.merged == true:
            (kind, verdict) = (.done, "Merged")
        case "closed":
            (kind, verdict) = (.note, "Closed without merging")
        default:
            // synchronize / labeled / edited / assigned …: churn, not news.
            return nil
        }

        return NotificationEvent(
            id: id(deliveryID),
            source: "github",
            title: p.pullRequest.title,
            subtitle: "\(verdict) · \(p.repository.fullName)#\(p.pullRequest.number)",
            thread: "gh:\(p.repository.fullName)#\(p.pullRequest.number)",
            kind: kind,
            actions: [openAction(label: "Open PR", url: p.pullRequest.htmlUrl)],
            metadata: metadata(event: "pull_request", repo: p.repository.fullName)
        )
    }

    private static func mentionEvent(deliveryID: String, payload: Data, login: String) -> NotificationEvent? {
        guard let p = try? decoder.decode(CommentPayload.self, from: payload),
              p.action == "created",
              let author = p.comment.user?.login,
              // Your own comments mention-ping nobody.
              author.caseInsensitiveCompare(login) != .orderedSame,
              mentions(login, in: p.comment.body ?? "")
        else { return nil }

        let subject = p.issue ?? p.pullRequest
        return NotificationEvent(
            id: id(deliveryID),
            source: "github",
            title: "\(author) mentioned you",
            subtitle: subject.map { "\(p.repository.fullName)#\($0.number) · \($0.title)" }
                ?? p.repository.fullName,
            body: p.comment.body,
            thread: subject.map { "gh:\(p.repository.fullName)#\($0.number)" },
            kind: .chat,
            actions: [openAction(label: "Open comment", url: p.comment.htmlUrl)],
            metadata: metadata(event: "comment", repo: p.repository.fullName)
        )
    }

    // MARK: - Shared pieces

    /// GitHub's delivery GUID *is* the dedupe key: a redelivery (manual, or a
    /// retry through a flaky tunnel) carries the same GUID, so the
    /// repository's id window drops it without the provider keeping state.
    private static func id(_ deliveryID: String) -> String { "github:\(deliveryID)" }

    /// `@login` as a word — `@julienmartel2` is somebody else. Logins are
    /// alphanumeric-plus-hyphen, so that's the boundary class.
    static func mentions(_ login: String, in body: String) -> Bool {
        let pattern = "@\(NSRegularExpression.escapedPattern(for: login))(?![A-Za-z0-9-])"
        return body.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func openAction(label: String, url: String) -> NotificationEvent.Action {
        NotificationEvent.Action(id: "open", label: label, kind: .openURL, target: url)
    }

    private static func metadata(event: String, repo: String?) -> [String: String] {
        var m = ["github.event": event]
        if let repo { m["github.repo"] = repo }
        return m
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}

// MARK: - Payload shapes (this file's quarantine zone)

private struct PingPayload: Decodable {
    struct Repository: Decodable { var fullName: String }
    struct Organization: Decodable { var login: String }
    var repository: Repository?
    var organization: Organization?
}

private struct WorkflowRunPayload: Decodable {
    struct Run: Decodable {
        var name: String?
        var displayTitle: String?
        var htmlUrl: String
        var conclusion: String?
        var headBranch: String?
    }
    struct Repository: Decodable { var fullName: String }
    var action: String?
    var workflowRun: Run
    var repository: Repository
}

private struct PullRequestPayload: Decodable {
    struct PR: Decodable {
        var number: Int
        var title: String
        var htmlUrl: String
        /// Only present-and-true on a `closed` action that merged.
        var merged: Bool?
    }
    struct User: Decodable { var login: String }
    struct Repository: Decodable { var fullName: String }
    var action: String?
    var pullRequest: PR
    var requestedReviewer: User?
    var repository: Repository
}

private struct CommentPayload: Decodable {
    struct User: Decodable { var login: String }
    struct Comment: Decodable {
        var body: String?
        var htmlUrl: String
        var user: User?
    }
    struct Subject: Decodable {
        var number: Int
        var title: String
    }
    struct Repository: Decodable { var fullName: String }
    var action: String?
    var comment: Comment
    var issue: Subject?
    var pullRequest: Subject?
    var repository: Repository
}
