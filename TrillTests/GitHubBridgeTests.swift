import CryptoKit
import XCTest
@testable import Trill

/// The GitHub bridge, headless: HMAC gate, HTTP parse, and payload→kind
/// mapping — every rule that decides what banners, without a socket or a
/// tunnel anywhere.
final class GitHubBridgeTests: XCTestCase {
    private let config = GitHubBridgeConfig(secret: "s3cret", login: "julienmartel")

    private func signature(_ body: Data, secret: String = "s3cret") -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8)))
        return "sha256=" + mac.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Signature

    func testSignatureAcceptsGitHubsFormat() {
        let body = Data(#"{"zen":"Keep it logically awesome."}"#.utf8)
        XCTAssertTrue(GitHubWebhookMapper.validSignature(
            header: signature(body), body: body, secret: "s3cret"
        ))
        // GitHub sends lowercase hex, but the check shouldn't hang on case.
        XCTAssertTrue(GitHubWebhookMapper.validSignature(
            header: signature(body).uppercased().replacingOccurrences(of: "SHA256", with: "sha256"),
            body: body, secret: "s3cret"
        ))
    }

    func testSignatureRejectsTamperMissingAndWrongSecret() {
        let body = Data(#"{"a":1}"#.utf8)
        XCTAssertFalse(GitHubWebhookMapper.validSignature(
            header: signature(body), body: Data(#"{"a":2}"#.utf8), secret: "s3cret"
        ))
        XCTAssertFalse(GitHubWebhookMapper.validSignature(header: nil, body: body, secret: "s3cret"))
        XCTAssertFalse(GitHubWebhookMapper.validSignature(
            header: signature(body, secret: "other"), body: body, secret: "s3cret"
        ))
    }

    // MARK: - HTTP parse

    func testParseCompletePost() throws {
        let raw = Data("POST /github HTTP/1.1\r\nHost: x\r\nX-GitHub-Event: ping\r\nContent-Length: 4\r\n\r\nbody".utf8)
        guard case .complete(let request) = HTTPRequest.parse(raw) else {
            return XCTFail("expected a complete request")
        }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/github")
        // Header names are case-insensitive on the wire; lookup is lowercase.
        XCTAssertEqual(request.headers["x-github-event"], "ping")
        XCTAssertEqual(request.body, Data("body".utf8))
    }

    func testParseWaitsForDeclaredBody() {
        let raw = Data("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nhalf".utf8)
        XCTAssertEqual(HTTPRequest.parse(raw), .incomplete)
    }

    func testParseRefusesOversizedDeclaredBody() {
        let raw = Data("POST / HTTP/1.1\r\nContent-Length: \(HTTPRequest.bodyLimit + 1)\r\n\r\n".utf8)
        XCTAssertEqual(HTTPRequest.parse(raw), .invalid)
    }

    func testParseRefusesNonHTTP() {
        XCTAssertEqual(HTTPRequest.parse(Data("nonsense\r\n\r\n".utf8)), .invalid)
    }

    // MARK: - workflow_run mapping

    private func workflowRun(conclusion: String, action: String = "completed") -> Data {
        Data("""
        {"action":"\(action)",
         "workflow_run":{"name":"CI","display_title":"fix the thing","html_url":"https://github.com/hausfold/trill/actions/runs/1","conclusion":"\(conclusion)","head_branch":"main"},
         "repository":{"full_name":"hausfold/trill"}}
        """.utf8)
    }

    func testRedRunIsAFault() throws {
        let event = try XCTUnwrap(GitHubWebhookMapper.event(
            name: "workflow_run", deliveryID: "d1", payload: workflowRun(conclusion: "failure"), login: "julienmartel"
        ))
        XCTAssertEqual(event.kind, .fault)
        XCTAssertEqual(event.id, "github:d1", "the delivery GUID is the dedupe key — a redelivery must collide")
        XCTAssertEqual(event.source, "github")
        XCTAssertEqual(event.title, "CI failed")
        XCTAssertEqual(event.thread, "gh-ci:hausfold/trill:CI")
        XCTAssertEqual(event.actions.first?.kind, .openURL)
        XCTAssertTrue(event.hasDefaultAction)
    }

    func testGreenRunIsDoneAndApprovalGateIsAnAsk() throws {
        XCTAssertEqual(try XCTUnwrap(GitHubWebhookMapper.event(
            name: "workflow_run", deliveryID: "d2", payload: workflowRun(conclusion: "success"), login: "x"
        )).kind, .done)
        XCTAssertEqual(try XCTUnwrap(GitHubWebhookMapper.event(
            name: "workflow_run", deliveryID: "d3", payload: workflowRun(conclusion: "action_required"), login: "x"
        )).kind, .ask)
    }

    func testCancelledAndInProgressRunsStaySilent() {
        XCTAssertNil(GitHubWebhookMapper.event(
            name: "workflow_run", deliveryID: "d4", payload: workflowRun(conclusion: "cancelled"), login: "x"
        ))
        XCTAssertNil(GitHubWebhookMapper.event(
            name: "workflow_run", deliveryID: "d5",
            payload: workflowRun(conclusion: "success", action: "in_progress"), login: "x"
        ))
    }

    // MARK: - review_requested mapping

    private func reviewRequest(reviewer: String?) -> Data {
        let reviewerJSON = reviewer.map { #","requested_reviewer":{"login":"\#($0)"}"# } ?? ""
        return Data("""
        {"action":"review_requested",
         "pull_request":{"number":12,"title":"banners: ledge","html_url":"https://github.com/hausfold/trill/pull/12"}\(reviewerJSON),
         "repository":{"full_name":"hausfold/trill"}}
        """.utf8)
    }

    func testReviewRequestForMeParksAsAnAsk() throws {
        let event = try XCTUnwrap(GitHubWebhookMapper.event(
            name: "pull_request", deliveryID: "d6",
            payload: reviewRequest(reviewer: "JulienMartel"), login: "julienmartel"
        ))
        XCTAssertEqual(event.kind, .ask, "an ask is what the Ledge parks — this is the bridge's headline mapping")
        XCTAssertEqual(event.title, "banners: ledge")
        XCTAssertEqual(event.subtitle, "Review requested · hausfold/trill#12")
        XCTAssertEqual(event.thread, "gh:hausfold/trill#12")
    }

    func testReviewRequestForSomeoneElseStaysSilent() {
        XCTAssertNil(GitHubWebhookMapper.event(
            name: "pull_request", deliveryID: "d7",
            payload: reviewRequest(reviewer: "someone-else"), login: "julienmartel"
        ))
        XCTAssertNil(GitHubWebhookMapper.event(
            name: "pull_request", deliveryID: "d8",
            payload: reviewRequest(reviewer: nil), login: "julienmartel"
        ), "a team review request names no reviewer — not mine to banner")
    }

    // MARK: - PR lifecycle mapping

    private func prLifecycle(action: String, merged: Bool = false) -> Data {
        Data("""
        {"action":"\(action)",
         "pull_request":{"number":13,"title":"github: more lifecycle","html_url":"https://github.com/hausfold/trill/pull/13","merged":\(merged)},
         "repository":{"full_name":"hausfold/trill"}}
        """.utf8)
    }

    func testPROpenedIsANote() throws {
        let event = try XCTUnwrap(GitHubWebhookMapper.event(
            name: "pull_request", deliveryID: "d17",
            payload: prLifecycle(action: "opened"), login: "julienmartel"
        ))
        XCTAssertEqual(event.kind, .note)
        XCTAssertEqual(event.subtitle, "PR opened · hausfold/trill#13")
        XCTAssertEqual(event.thread, "gh:hausfold/trill#13")
    }

    func testMergedPRIsDoneAndUnmergedCloseIsANote() throws {
        let merged = try XCTUnwrap(GitHubWebhookMapper.event(
            name: "pull_request", deliveryID: "d18",
            payload: prLifecycle(action: "closed", merged: true), login: "julienmartel"
        ))
        XCTAssertEqual(merged.kind, .done)
        XCTAssertEqual(merged.subtitle, "Merged · hausfold/trill#13")

        let closed = try XCTUnwrap(GitHubWebhookMapper.event(
            name: "pull_request", deliveryID: "d19",
            payload: prLifecycle(action: "closed", merged: false), login: "julienmartel"
        ))
        XCTAssertEqual(closed.kind, .note)
        XCTAssertEqual(closed.subtitle, "Closed without merging · hausfold/trill#13")
    }

    func testPRChurnStaysSilent() {
        XCTAssertNil(GitHubWebhookMapper.event(
            name: "pull_request", deliveryID: "d20",
            payload: prLifecycle(action: "synchronize"), login: "julienmartel"
        ), "every push to a PR branch fires synchronize — churn, not news")
    }

    // MARK: - mention mapping

    private func comment(body: String, author: String) -> Data {
        Data("""
        {"action":"created",
         "comment":{"body":"\(body)","html_url":"https://github.com/hausfold/trill/issues/3#c1","user":{"login":"\(author)"}},
         "issue":{"number":3,"title":"fins overlap"},
         "repository":{"full_name":"hausfold/trill"}}
        """.utf8)
    }

    func testMentionIsAChat() throws {
        let event = try XCTUnwrap(GitHubWebhookMapper.event(
            name: "issue_comment", deliveryID: "d9",
            payload: comment(body: "@julienmartel does this park?", author: "collaborator"), login: "julienmartel"
        ))
        XCTAssertEqual(event.kind, .chat)
        XCTAssertEqual(event.title, "collaborator mentioned you")
        XCTAssertEqual(event.subtitle, "hausfold/trill#3 · fins overlap")
    }

    func testNonMentionsAndOwnCommentsStaySilent() {
        XCTAssertNil(GitHubWebhookMapper.event(
            name: "issue_comment", deliveryID: "d10",
            payload: comment(body: "no ping here", author: "collaborator"), login: "julienmartel"
        ))
        XCTAssertNil(GitHubWebhookMapper.event(
            name: "issue_comment", deliveryID: "d11",
            payload: comment(body: "@julienmartel note to self", author: "JulienMartel"), login: "julienmartel"
        ), "your own comments mention-ping nobody")
        XCTAssertNil(GitHubWebhookMapper.event(
            name: "issue_comment", deliveryID: "d12",
            payload: comment(body: "cc @julienmartel2", author: "collaborator"), login: "julienmartel"
        ), "@julienmartel2 is somebody else — logins end at a word boundary")
    }

    // MARK: - ping + unknowns

    func testPingBannersOnceAsSetupFeedback() throws {
        let payload = Data(#"{"zen":"Speak like a human.","organization":{"login":"hausfold"}}"#.utf8)
        let event = try XCTUnwrap(GitHubWebhookMapper.event(
            name: "ping", deliveryID: "d13", payload: payload, login: "julienmartel"
        ))
        XCTAssertEqual(event.kind, .note)
        XCTAssertEqual(event.subtitle, "webhook live for hausfold")
    }

    func testUnknownEventsMapToNothing() {
        XCTAssertNil(GitHubWebhookMapper.event(
            name: "watch", deliveryID: "d14", payload: Data("{}".utf8), login: "julienmartel"
        ))
    }

    // MARK: - The provider's accept/reject seam

    func testHandleRejectsUnsignedAndNonPost() {
        var yielded: [NotificationEvent] = []
        let body = workflowRun(conclusion: "failure")

        let unsigned = HTTPRequest(method: "POST", path: "/", headers: ["x-github-event": "workflow_run", "x-github-delivery": "d"], body: body)
        XCTAssertEqual(GitHubWebhookProvider.handle(unsigned, config: config) { yielded.append($0) }, 401)

        let get = HTTPRequest(method: "GET", path: "/", headers: [:], body: Data())
        XCTAssertEqual(GitHubWebhookProvider.handle(get, config: config) { yielded.append($0) }, 405)

        XCTAssertTrue(yielded.isEmpty, "nothing unsigned may become an event")
    }

    func testHandleYieldsSignedDeliveries() {
        var yielded: [NotificationEvent] = []
        let body = workflowRun(conclusion: "failure")
        let signed = HTTPRequest(
            method: "POST", path: "/",
            headers: [
                "x-hub-signature-256": signature(body),
                "x-github-event": "workflow_run",
                "x-github-delivery": "d15",
            ],
            body: body
        )
        XCTAssertEqual(GitHubWebhookProvider.handle(signed, config: config) { yielded.append($0) }, 200)
        XCTAssertEqual(yielded.map(\.id), ["github:d15"])

        // An ignored-but-valid event is still a 200 — GitHub's delivery log
        // should show green for everything it faithfully delivered.
        var ignored: [NotificationEvent] = []
        let cancelled = workflowRun(conclusion: "cancelled")
        let signedIgnored = HTTPRequest(
            method: "POST", path: "/",
            headers: [
                "x-hub-signature-256": signature(cancelled),
                "x-github-event": "workflow_run",
                "x-github-delivery": "d16",
            ],
            body: cancelled
        )
        XCTAssertEqual(GitHubWebhookProvider.handle(signedIgnored, config: config) { ignored.append($0) }, 200)
        XCTAssertTrue(ignored.isEmpty)
    }

    // MARK: - Resolution (the bridge answering its own asks)

    func testMergingAPRTakesItsReviewRequestFinDown() throws {
        let ask = try XCTUnwrap(GitHubWebhookMapper.event(
            name: "pull_request", deliveryID: "r1",
            payload: reviewRequest(reviewer: "julienmartel"), login: "julienmartel"
        ))
        XCTAssertEqual(
            ask.key, "gh:hausfold/trill#12",
            "the ask claims the PR's name so a later delivery can answer it"
        )
        XCTAssertTrue(ask.resolves.isEmpty, "a question answers nothing")

        let merged = try XCTUnwrap(GitHubWebhookMapper.event(
            name: "pull_request", deliveryID: "r2",
            payload: prLifecycle(action: "closed", merged: true), login: "julienmartel"
        ))
        XCTAssertEqual(merged.resolves, ["gh:hausfold/trill#13"])
        XCTAssertNil(merged.key, "an ending doesn't claim the name, it answers it")

        // Closed without merging is just as final for the reviewer.
        XCTAssertEqual(try XCTUnwrap(GitHubWebhookMapper.event(
            name: "pull_request", deliveryID: "r3",
            payload: prLifecycle(action: "closed", merged: false), login: "julienmartel"
        )).resolves, ["gh:hausfold/trill#13"])
    }

    func testOpeningAPROrMentioningYouResolvesNothing() throws {
        let opened = try XCTUnwrap(GitHubWebhookMapper.event(
            name: "pull_request", deliveryID: "r4",
            payload: prLifecycle(action: "opened"), login: "julienmartel"
        ))
        XCTAssertNil(opened.key)
        XCTAssertTrue(opened.resolves.isEmpty)

        // A mention shares the PR's *thread* and means something else
        // entirely. If it claimed the key it would supersede the fin for a
        // review nobody did.
        let mention = try XCTUnwrap(GitHubWebhookMapper.event(
            name: "issue_comment", deliveryID: "r5",
            payload: comment(body: "@julienmartel look", author: "someone"), login: "julienmartel"
        ))
        XCTAssertNil(mention.key)
        XCTAssertTrue(mention.resolves.isEmpty)
    }

    func testAFinishedRunAnswersTheRunThatWasWaitingForApproval() throws {
        let gate = try XCTUnwrap(GitHubWebhookMapper.event(
            name: "workflow_run", deliveryID: "r6",
            payload: workflowRun(conclusion: "action_required"), login: "x"
        ))
        XCTAssertEqual(gate.kind, .ask)
        XCTAssertEqual(gate.key, "gh-ci:hausfold/trill:CI")

        for conclusion in ["success", "failure"] {
            let done = try XCTUnwrap(GitHubWebhookMapper.event(
                name: "workflow_run", deliveryID: "r7-\(conclusion)",
                payload: workflowRun(conclusion: conclusion), login: "x"
            ))
            XCTAssertEqual(
                done.resolves, ["gh-ci:hausfold/trill:CI"],
                "however it ended, it is no longer waiting on a human"
            )
            XCTAssertNil(done.key)
        }
    }
}
