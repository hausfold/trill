import XCTest
@testable import Trill

/// System Mirror, headless: what one usernoted row becomes, and what trill
/// refuses to mirror. Every plist here is the shape measured on a real store
/// (macOS 26, 2026-08-25) — Messages' localization-free body, Find My's
/// localization triple, Tips posting with no title at all — so a schema change
/// shows up as a red test rather than an empty screen.
final class SystemMirrorTests: XCTestCase {
    private let delivered = 809_311_966.4  // 2026-08-24, in usernoted's 2001 epoch

    private func record(
        recordID: Int64 = 1,
        uuid: UUID? = UUID(uuidString: "4C5B26E0-03E1-43D1-80C9-87453B668F2A"),
        style: Int = 0,
        app: String = "com.apple.MobileSMS",
        request: [String: Any] = ["titl": "+1 (660) 600-7145", "body": "on my way"]
    ) -> UsernotedRecord? {
        UsernotedRecord(
            recordID: recordID, uuid: uuid, style: style, deliveredDate: delivered,
            plist: ["app": app, "req": request]
        )
    }

    // MARK: - Which apps the mirror is allowed to draw

    func testAnUnchosenListMirrorsEveryApp() {
        XCTAssertTrue(SystemMirrorMapper.isAllowed("com.tinyspeck.slackmacgap", allowing: nil))
    }

    func testOnlyTickedAppsAreMirroredOnceAListExists() {
        let ticked: Set<String> = ["com.apple.mobilesms"]
        XCTAssertTrue(SystemMirrorMapper.isAllowed("com.apple.MobileSMS", allowing: ticked))
        XCTAssertFalse(SystemMirrorMapper.isAllowed("com.tinyspeck.slackmacgap", allowing: ticked))
    }

    /// Unticking every app means the mirror draws nothing — not that it goes
    /// back to drawing everything. That distinction is the whole reason the
    /// list is optional rather than an array that means "all" when empty.
    func testAnEmptyListMirrorsNothing() {
        XCTAssertFalse(SystemMirrorMapper.isAllowed("com.apple.MobileSMS", allowing: []))
    }

    /// A tick is stored as a slug, and usernoted files some rows under its own
    /// internal prefix — the same normalization rules.json gets.
    func testATickMatchesThePrefixedFormOfTheSameApp() {
        let ticked: Set<String> = ["com.apple.softwareupdatenotification"]
        XCTAssertTrue(SystemMirrorMapper.isAllowed(
            "_SYSTEM_CENTER_:com.apple.SoftwareUpdateNotification", allowing: ticked
        ))
    }

    // MARK: - The row

    func testDecodesAMessagesRow() throws {
        let record = try XCTUnwrap(self.record(request: [
            "titl": "#design-review",
            "subt": "Ada Fenwick mentioned you",
            "body": "corner radius?",
            "thre": "any;-;+16606007145",
            "cate": "com.apple.messages.IncomingMessageCategory.SMS",
            "durl": "messages://open?groupid=x",
            "unct": "UNNotificationContentTypeMessagingDirect",
        ]))
        XCTAssertEqual(record.bundleID, "com.apple.MobileSMS")
        XCTAssertEqual(record.title, "#design-review")
        XCTAssertEqual(record.subtitle, "Ada Fenwick mentioned you")
        XCTAssertEqual(record.body, "corner radius?")
        XCTAssertEqual(record.threadID, "any;-;+16606007145")
        XCTAssertEqual(record.destinationURL, "messages://open?groupid=x")
        XCTAssertEqual(record.deliveredAt, Date(timeIntervalSinceReferenceDate: delivered))
    }

    /// Find My posts `body` as `[localizationKey, resolvedSentence, [args]]`.
    /// Element 1 is the only part anybody wrote in words.
    func testBodyMayBeALocalizationTriple() throws {
        let record = try XCTUnwrap(self.record(app: "com.apple.findmy", request: [
            "body": [
                "PUSH_OFFER_LOCATION_SHARE_BACK",
                "Mackenzie started sharing location with you.",
                ["Mackenzie", "Pyne"],
            ] as [Any],
        ]))
        XCTAssertEqual(record.body, "Mackenzie started sharing location with you.")
        XCTAssertNil(record.title)
    }

    func testRefusesATripleWhoseSentenceIsntOne() {
        XCTAssertNil(UsernotedRecord.text(["KEY", ["not", "a", "sentence"]] as [Any]))
        XCTAssertNil(UsernotedRecord.text(["KEY"] as [Any]))
        XCTAssertNil(UsernotedRecord.text(nil))
        XCTAssertNil(UsernotedRecord.text("   "))
    }

    /// No title and no body is a badge update, not a notification.
    func testSkipsRowsWithNothingToDraw() {
        XCTAssertNil(UsernotedRecord(
            recordID: 1, uuid: nil, style: 0, deliveredDate: delivered,
            plist: ["app": "com.apple.mail", "req": ["badg": 3]]
        ))
        XCTAssertNil(UsernotedRecord(
            recordID: 1, uuid: nil, style: 0, deliveredDate: delivered,
            plist: ["req": ["titl": "orphan"]]
        ))
    }

    // MARK: - The slug

    func testStripsUsernotedsSystemCentrePrefix() {
        XCTAssertEqual(
            SystemMirrorMapper.source(for: "_SYSTEM_CENTER_:com.apple.SoftwareUpdateNotification"),
            "com.apple.softwareupdatenotification"
        )
        XCTAssertEqual(
            SystemMirrorMapper.source(for: "com.apple.SoftwareUpdateNotification"),
            "com.apple.softwareupdatenotification"
        )
    }

    /// The prefixed and bare forms of one app must land on the same rule.
    func testOneRuleCatchesBothFormsOfASystemApp() {
        let rule = RuleSet.Rule(
            match: .init(source: "com.apple.SoftwareUpdateNotification"), delivery: .inbox
        )
        for identifier in [
            "com.apple.SoftwareUpdateNotification",
            "_SYSTEM_CENTER_:com.apple.SoftwareUpdateNotification",
        ] {
            let record = self.record(app: identifier, request: ["titl": "Update Available"])
            let event = SystemMirrorMapper.event(for: try! XCTUnwrap(record))
            XCTAssertTrue(rule.match.matches(try! XCTUnwrap(event)), "\(identifier) missed its rule")
        }
    }

    // MARK: - The feedback loop

    func testNeverMirrorsItsOwnBanners() throws {
        for identifier in SystemMirrorMapper.ownBundleIDs {
            let record = try XCTUnwrap(self.record(app: identifier, request: ["titl": "Deploy landed"]))
            XCTAssertNil(SystemMirrorMapper.event(for: record), "\(identifier) fed back in")
        }
    }

    func testNeverMirrorsTheRunningBuildEitherIfItGetsRenamed() throws {
        let record = try XCTUnwrap(self.record(app: "co.example.trill.renamed", request: ["titl": "hi"]))
        XCTAssertNil(SystemMirrorMapper.event(
            for: record, runningBundleID: "co.example.trill.renamed"
        ))
    }

    // MARK: - The card

    func testTitlesWithTheAppWhenTheNotificationDidnt() throws {
        let record = try XCTUnwrap(self.record(app: "com.apple.tips", request: [
            "body": "Learn how to use the Phone app on Mac.",
        ]))
        let event = try XCTUnwrap(SystemMirrorMapper.event(for: record))
        XCTAssertEqual(event.title, "Tips")
        XCTAssertEqual(event.body, "Learn how to use the Phone app on Mac.")
    }

    func testPrefersTheResolvedAppName() throws {
        let record = try XCTUnwrap(self.record(app: "com.apple.mobilesms", request: ["body": "hi"]))
        let event = try XCTUnwrap(SystemMirrorMapper.event(for: record, appName: "Messages"))
        XCTAssertEqual(event.title, "Messages")
    }

    func testMessagingContentTypeReadsAsChat() throws {
        let chat = try XCTUnwrap(self.record(request: [
            "titl": "Ada", "body": "hi", "unct": "UNNotificationContentTypeMessagingDirect",
        ]))
        XCTAssertEqual(try XCTUnwrap(SystemMirrorMapper.event(for: chat)).kind, .chat)

        let note = try XCTUnwrap(self.record(app: "com.apple.tips", request: ["titl": "Tip", "body": "x"]))
        XCTAssertEqual(try XCTUnwrap(SystemMirrorMapper.event(for: note)).kind, .note)
    }

    /// Two apps may both call a thread "1"; they are not the same thread.
    func testThreadsAreNamespacedByApp() throws {
        let record = try XCTUnwrap(self.record(request: ["titl": "a", "thre": "1"]))
        XCTAssertEqual(try XCTUnwrap(SystemMirrorMapper.event(for: record)).thread, "com.apple.mobilesms:1")
    }

    /// Both pills must be pressable — trill draws no dead buttons — and the
    /// private `durl` scheme must never become one of them.
    func testDrawsOnlyPillsThatWork() throws {
        let record = try XCTUnwrap(self.record(request: [
            "titl": "a", "durl": "messages://open?groupid=x",
        ]))
        let event = try XCTUnwrap(SystemMirrorMapper.event(for: record, appName: "Messages"))
        XCTAssertEqual(event.actions.map(\.kind), [.openApp, .silenceNative])
        XCTAssertTrue(event.actions.allSatisfy(\.isPerformable))
        XCTAssertFalse(event.actions.contains { $0.kind == .openURL })
        XCTAssertEqual(event.metadata["destination"], "messages://open?groupid=x")
    }

    /// Whether macOS drew its own banner is carried, never acted on: the
    /// helper is what silences apps, and it is the user's click.
    func testCarriesWhetherMacOSDrewItToo() throws {
        for style in [0, 1] {
            let record = try XCTUnwrap(self.record(style: style, request: ["titl": "a"]))
            let event = try XCTUnwrap(SystemMirrorMapper.event(for: record))
            XCTAssertEqual(event.metadata["nativeStyle"], String(style))
        }
    }

    /// The uuid is the dedupe id, so the same row read twice across a restart
    /// is one card.
    func testIdentityComesFromTheRowsUUID() throws {
        let uuid = UUID()
        let record = try XCTUnwrap(self.record(uuid: uuid, request: ["titl": "a"]))
        XCTAssertEqual(try XCTUnwrap(SystemMirrorMapper.event(for: record)).id, uuid.uuidString)

        let anonymous = try XCTUnwrap(self.record(recordID: 42, uuid: nil, request: ["titl": "a"]))
        XCTAssertEqual(try XCTUnwrap(SystemMirrorMapper.event(for: anonymous)).id, "usernoted-42")
    }
}
