import XCTest
@testable import Trill

/// The flag decoding is reverse-engineered, so these tests pin it against
/// **real** values lifted out of a live `com.apple.ncprefs.plist` rather than
/// against numbers invented to match the implementation. If a macOS update
/// moves the layout, this is where it should fail.
final class NotificationSettingsAuditTests: XCTestCase {
    private func decode(_ flags: UInt64) -> NativeNotificationSettings {
        NotificationSettingsAudit.decode(bundleID: "com.example.app", flags: flags)
    }

    /// Most of these tests are about style/sound, not the master switch, so
    /// they say "and notifications are allowed" once, here, rather than
    /// carrying bit 25 through every literal.
    private func decodeAllowed(_ flags: UInt64) -> NativeNotificationSettings {
        decode(flags | 1 << 25)
    }

    // MARK: - Pinned against System Settings itself

    /// Real flag words paired with what System Settings *actually displayed*
    /// for that app, read off the pane by hand. This is the corroboration the
    /// `allowNotifications` bit rests on — if a macOS update moves it, these
    /// fail, and that's the point.
    ///
    /// The lone documented miss (`com.openai.chat`, never prompted, `auth ==
    /// 0`) is included and asserted as a miss rather than quietly omitted:
    /// a known limitation you can see is worth more than a clean-looking
    /// suite that hides it.
    private static let systemSettingsGroundTruth: [(bundleID: String, flags: UInt64, isOn: Bool)] = [
        ("com.apple.iCal", 814_219_286, false),
        ("com.federicoterzi.espanso", 8_396_814, false),
        ("com.apple.appleseed.FeedbackAssistant", 268_443_662, false),
        ("com.mitchellh.ghostty", 276_832_270, false),
        ("com.google.Chrome", 8_396_814, false),
        ("com.google.Chrome.framework.AlertNotificationService", 8_396_822, false),
        ("com.apple.mail", 276_824_078, false),
        ("com.apple.Music", 276_832_270, false),
        ("com.apple.Notes", 276_832_270, false),
        ("com.cron.electron", 8_396_822, false),
        ("com.apple.Photos", 276_832_270, false),
        ("com.apple.weather", 295_706_638, false),
        ("io.tailscale.ipn.macsys", 276_832_270, false),
        ("com.apple.dt.Xcode", 276_832_270, false),
        ("so.cap.desktop", 41_951_246, true),
        ("com.anthropic.claudefordesktop", 310_386_766, true),
        ("company.thebrowser.dia", 310_386_702, true),
    ]

    func testAllowBitMatchesWhatSystemSettingsShows() {
        for row in Self.systemSettingsGroundTruth {
            let decoded = NotificationSettingsAudit.decode(bundleID: row.bundleID, flags: row.flags)
            XCTAssertEqual(
                decoded.allowsNotifications, row.isOn,
                "\(row.bundleID): System Settings shows \(row.isOn ? "on" : "Off")"
            )
            XCTAssertEqual(
                decoded.settingsSubtitle == "Off", !row.isOn,
                "\(row.bundleID): subtitle should agree with the switch"
            )
        }
    }

    func testSilencedAppsAreNeverReportedAsNoisy() {
        // The bug this bit exists to fix: ghostty reads as banners + sound,
        // but the user turned it off years ago and System Settings says Off.
        let ghostty = NotificationSettingsAudit.decode(
            bundleID: "com.mitchellh.ghostty", flags: 276_832_270
        )
        XCTAssertEqual(ghostty.desktopAlert, .temporary)
        XCTAssertTrue(ghostty.playsSound)
        XCTAssertFalse(ghostty.isNoisy, "notifications are off — the stale style bits don't matter")
    }

    func testTheKnownMissIsStillTheOnlyMiss() {
        // ChatGPT: never prompted (auth == 0), so no decision is recorded and
        // the bit reads off while System Settings shows it on. trill stays
        // quiet about it — under-reporting, which is the safe direction.
        let chatGPT = NotificationSettingsAudit.decode(
            bundleID: "com.openai.chat", flags: 268_443_662
        )
        XCTAssertFalse(chatGPT.allowsNotifications)
        XCTAssertFalse(chatGPT.isNoisy)
    }

    func testRowsSystemSettingsDoesNotListAreMarked() {
        // com.apple.clock — confirmed absent from Application Notifications.
        XCTAssertFalse(decodeReal("com.apple.clock", 8_917_622_934).hasSettingsRow)
        // A normal app keeps its row.
        XCTAssertTrue(decodeReal("com.tinyspeck.slackmacgap", 310_386_702).hasSettingsRow)
    }

    func testEverythingHidesAppsWithNoSettingsRow() {
        let all = [
            decodeReal("com.apple.clock", 8_917_622_934),
            decodeReal("com.tinyspeck.slackmacgap", 310_386_702),
        ]
        let keyed = Dictionary(all.map { ($0.bundleID, $0) }, uniquingKeysWith: { _, l in l })
        let found = NotificationSettingsAudit.findings(
            scope: .everything, settings: keyed, isInstalled: { _ in true }
        )
        XCTAssertEqual(found.map(\.bundleID), ["com.tinyspeck.slackmacgap"])
    }

    private func decodeReal(_ bundleID: String, _ flags: UInt64) -> NativeNotificationSettings {
        NotificationSettingsAudit.decode(bundleID: bundleID, flags: flags)
    }

    // MARK: - Alert style

    func testTemporaryAlertFromRealFlags() {
        // com.tinyspeck.slackmacgap — Desktop (temporary), sound, badge, allowed.
        let settings = decode(310_386_702)
        XCTAssertEqual(settings.desktopAlert, .temporary)
        XCTAssertTrue(settings.playsSound)
        XCTAssertTrue(settings.badgesIcon)
        XCTAssertTrue(settings.isNoisy)
    }

    func testPersistentAlertFromRealFlags() {
        // com.apple.reminders — Desktop ✓ / Persistent, confirmed against the
        // Tahoe pane itself, and still allowed.
        let settings = decode(9_437_708_310)
        XCTAssertEqual(settings.desktopAlert, .persistent)
        XCTAssertTrue(settings.isNoisy)
    }

    func testDesktopUntickedFromRealFlags() {
        // com.apple.Home — Desktop unticked.
        let settings = decode(2_986_868_742)
        XCTAssertEqual(settings.desktopAlert, .off)
    }

    func testTemporaryWinsWhenBothAlertBitsAreSet() {
        // Not a state System Settings can produce, but the store is Apple's
        // and undocumented: decode it deterministically instead of trapping.
        XCTAssertEqual(decode(0b11000).desktopAlert, .temporary)
    }

    // MARK: - Sound and badge

    func testSoundBitIsIndependentOfTheDesktopAlert() {
        XCTAssertTrue(decode(0b00100).playsSound)
        XCTAssertFalse(decode(0b11011).playsSound)
    }

    func testBadgeBit() {
        XCTAssertTrue(decode(0b00010).badgesIcon)
        XCTAssertFalse(decode(0b11101).badgesIcon)
    }

    // MARK: - Noisiness is the only question that matters

    func testSilentAppIsNotNoisy() {
        // Desktop unticked, no sound: the state the helper walks users to.
        let settings = decodeAllowed(0b00010)
        XCTAssertFalse(settings.isNoisy)
        XCTAssertNil(settings.complaint)
    }

    func testSoundAloneIsStillNoisy() {
        // Desktop unticked but "Play sound" left on — the case a
        // Desktop-only check would miss.
        let settings = decodeAllowed(0b00100)
        XCTAssertEqual(settings.desktopAlert, .off)
        XCTAssertTrue(settings.isNoisy)
        XCTAssertEqual(settings.complaint, "macOS still shows this with a sound")
    }

    // MARK: - The System Settings summary line

    func testSubtitleMatchesTheStringSystemSettingsWrites() {
        // Real ghostty flags: badge + sound + banners.
        XCTAssertEqual(decodeAllowed(276_832_270).settingsSubtitle, "Badges, Sounds, and Desktop")
    }

    func testSubtitleTwoPartsUsesAndWithoutAComma() {
        XCTAssertEqual(decodeAllowed(0b00110).settingsSubtitle, "Badges and Sounds")
    }

    func testSubtitleOfASilencedAppIsOff() {
        XCTAssertEqual(decode(0).settingsSubtitle, "Off")
    }

    func testComplaintNamesBothProblems() {
        XCTAssertEqual(decodeAllowed(0b01100).complaint, "macOS still shows this on the Desktop, with a sound")
    }

    // MARK: - The apps array

    private func entry(_ bundleID: String, _ flags: UInt64) -> [String: Any] {
        ["bundle-id": bundleID, "flags": NSNumber(value: flags)]
    }

    func testSystemManagedEntriesAreDropped() {
        let decoded = NotificationSettingsAudit.decode(appsArray: [
            entry("_SYSTEM_CENTER_:com.apple.mdmclient", 41_943_575),
            entry("com.tinyspeck.slackmacgap", 310_386_702),
        ])
        XCTAssertEqual(decoded.map(\.bundleID), ["com.tinyspeck.slackmacgap"])
    }

    func testEntriesWithoutFlagsAreSkippedNotGuessed() {
        let decoded = NotificationSettingsAudit.decode(appsArray: [
            ["bundle-id": "com.example.broken"],
            entry("com.example.fine", 0b01110),
        ])
        XCTAssertEqual(decoded.map(\.bundleID), ["com.example.fine"])
    }

    func testFlagsWiderThan32BitsSurvive() {
        // com.apple.MobileSMS on this macOS: bit 33 is set, so a UInt32
        // decode would silently lose the top half.
        let decoded = NotificationSettingsAudit.decode(appsArray: [
            entry("com.apple.MobileSMS", 9_490_137_102),
        ])
        XCTAssertEqual(decoded.first?.desktopAlert, .temporary)
    }

    // MARK: - Scoping

    private var fixture: [String: NativeNotificationSettings] {
        let all = NotificationSettingsAudit.decode(appsArray: [
            entry("com.apple.reminders", 9_437_708_310),     // alerts + sound, allowed
            entry("com.tinyspeck.slackmacgap", 310_386_702), // banners + sound, allowed
            entry("com.quiet.app", 0b00010 | 1 << 25),       // allowed, already silent
        ])
        return Dictionary(all.map { ($0.bundleID, $0) }, uniquingKeysWith: { _, l in l })
    }

    func testFindingsSkipAlreadySilentApps() {
        let found = NotificationSettingsAudit.findings(
            scope: .everything, settings: fixture, isInstalled: { _ in true }
        )
        XCTAssertEqual(Set(found.map(\.bundleID)), ["com.apple.reminders", "com.tinyspeck.slackmacgap"])
    }

    func testFindingsRankAlertsAboveBanners() {
        let found = NotificationSettingsAudit.findings(
            scope: .everything, settings: fixture, isInstalled: { _ in true }
        )
        XCTAssertEqual(found.first?.bundleID, "com.apple.reminders")
    }

    func testOnlyScopeIgnoresUnlistedApps() {
        let found = NotificationSettingsAudit.findings(
            scope: .only(["com.tinyspeck.slackmacgap"]), settings: fixture
        )
        XCTAssertEqual(found.map(\.bundleID), ["com.tinyspeck.slackmacgap"])
    }

    func testOnlyScopeToleratesUnknownBundleIDs() {
        let found = NotificationSettingsAudit.findings(
            scope: .only(["com.not.installed"]), settings: fixture
        )
        XCTAssertTrue(found.isEmpty)
    }

    func testEverythingSkipsBundleIDsNothingOnThisMacClaims() {
        // The invisible system agents: a preferences row, but no app, no
        // recognisable System Settings entry, and nothing trill would mirror.
        let found = NotificationSettingsAudit.findings(
            scope: .everything,
            settings: fixture,
            isInstalled: { $0 != "com.apple.reminders" }
        )
        XCTAssertEqual(found.map(\.bundleID), ["com.tinyspeck.slackmacgap"])
    }

    func testNamedAppsAreReportedEvenWhenUninstalled() {
        // Explicitly asked for, so answer — silently dropping it would read
        // as the audit being broken.
        let found = NotificationSettingsAudit.findings(
            scope: .only(["com.apple.reminders"]),
            settings: fixture,
            isInstalled: { _ in false }
        )
        XCTAssertEqual(found.map(\.bundleID), ["com.apple.reminders"])
    }

    func testListedBundleIDsTakesOnlyBundleShapedSources() {
        let rules = RuleSet(
            rules: [
                .init(match: .init(source: "com.tinyspeck.slackmacgap"), delivery: .banner),
                .init(match: .init(source: "deploy"), delivery: .inbox),
                .init(match: .init(source: "com.tinyspeck.slackmacgap"), delivery: .drop),
                .init(match: .init(titleContains: "build"), delivery: .drop),
            ],
            quietHours: nil
        )
        XCTAssertEqual(
            NotificationSettingsAudit.listedBundleIDs(in: rules),
            ["com.tinyspeck.slackmacgap"]
        )
    }

    // MARK: - What the audit puts on screen

    func testNothingFoundMeansNoBanners() {
        XCTAssertTrue(NotificationSettingsAudit.bannerEvents(for: []).isEmpty)
    }

    func testEachFindingGetsItsOwnBannerUpToTheLimit() {
        let findings = NotificationSettingsAudit.findings(scope: .everything, settings: fixture)
        let events = NotificationSettingsAudit.bannerEvents(for: findings)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?.actions.first?.kind, .silenceNative)
        // Each carries the app it's about, so the helper opens on that one.
        XCTAssertEqual(
            Set(events.compactMap(\.actions.first?.target)),
            Set(findings.map(\.bundleID))
        )
    }

    func testTooManyFindingsCollapseToOneSummaryBanner() {
        let many = (0...NotificationSettingsAudit.individualBannerLimit).map {
            NotificationSettingsAudit.decode(bundleID: "com.example.app\($0)", flags: 0b01110 | 1 << 25)
        }
        let events = NotificationSettingsAudit.bannerEvents(for: many)
        XCTAssertEqual(events.count, 1)
        XCTAssertTrue(events[0].title.contains("\(many.count) apps"))
        // The summary still names every app it counted, so the click walks
        // exactly those — not whatever a fresh whole-Mac audit turns up.
        XCTAssertEqual(
            NotificationSettingsAudit.scope(forActionTarget: events[0].actions.first?.target),
            .only(many.map(\.bundleID))
        )
    }

    func testASummaryBannerNeverWidensTheScopeItWasAuditedWith() {
        // The audit that produced the banner was scoped to one listed app;
        // the other noisy app on this Mac was never listed. The banner's
        // target has to carry that scope, or the click re-audits the lot.
        let listed = NotificationSettingsAudit.findings(
            scope: .only(["com.tinyspeck.slackmacgap"]),
            settings: fixture,
            isInstalled: { _ in true }
        )
        let target = NotificationSettingsAudit.actionTarget(for: listed)
        XCTAssertEqual(
            NotificationSettingsAudit.scope(forActionTarget: target),
            .only(["com.tinyspeck.slackmacgap"])
        )
        // com.apple.reminders is noisy in the fixture and deliberately absent.
        XCTAssertFalse(target.contains("com.apple.reminders"))
    }

    func testATargetlessSilenceActionNamesNothing() {
        // nil is the one honest answer here: the caller decides what to fall
        // back to (the listed apps), and it is never "every app".
        XCTAssertNil(NotificationSettingsAudit.scope(forActionTarget: nil))
        XCTAssertNil(NotificationSettingsAudit.scope(forActionTarget: ""))
        XCTAssertNil(NotificationSettingsAudit.scope(forActionTarget: " , "))
    }

    func testBannersShareAThreadSoTheyCoalesceRatherThanPileUp() {
        let findings = NotificationSettingsAudit.findings(scope: .everything, settings: fixture)
        let threads = Set(NotificationSettingsAudit.bannerEvents(for: findings).compactMap(\.thread))
        XCTAssertEqual(threads, ["trill-doctor"])
    }

    // MARK: - Can't-tell is a third answer

    /// The store moved on macOS 26 — `com.apple.ncprefs` is a stale mirror,
    /// and the real one lives in an Apple group container behind Full Disk
    /// Access. So a reader without the grant gets nothing, and the one thing
    /// it must never do is call that "quiet".
    func testAnUnreadableStoreIsNilNotAnEmptyWorklist() {
        // Whatever this machine's grant state, the two answers must not be
        // the same shape: nil means "couldn't look", [] means "looked, all
        // quiet". This pins the type, which is what stops the confusion.
        let live: [NativeNotificationSettings]? = NotificationSettingsAudit.liveFindings(
            scope: .only(["com.example.definitely.not.installed"]),
            isInstalled: { _ in true }
        )
        if let live {
            // Store readable: an app macOS has no row for is simply absent.
            XCTAssertTrue(live.isEmpty)
            XCTAssertNil(NotificationSettingsAudit.unreadableReason())
        } else {
            // Store unreadable: there must be a reason to show the user, and
            // it must name the grant they need.
            let reason = NotificationSettingsAudit.unreadableReason()
            XCTAssertNotNil(reason)
            XCTAssertTrue(reason?.contains("Full Disk Access") == true)
        }
    }

    /// An app trill couldn't read is walked through as if both controls were
    /// on: naming a switch that's already off costs a glance, staying quiet
    /// about one that's on costs the duplicate banner.
    func testAnUnknownAppAsksForBothControls() {
        let unknown = NativeNotificationSettings.unknown(bundleID: "com.example.app")
        XCTAssertTrue(unknown.showsOnDesktop)
        XCTAssertTrue(unknown.playsSound)
        XCTAssertTrue(unknown.isNoisy)
        XCTAssertTrue(unknown.hasSettingsRow)
    }

    // MARK: - The doctor wire verb

    private func doctorRequest(_ json: String) -> SocketProvider.DoctorRequest? {
        guard case .doctor(let request) = SocketProvider.handle(line: Data(json.utf8)) else {
            return nil
        }
        return request
    }

    func testBareDoctorLetsTheDaemonPickTheScope() {
        let request = doctorRequest(#"{"verb":"doctor"}"#)
        XCTAssertNil(request?.scope)
        XCTAssertEqual(request?.notify, false)
    }

    func testDoctorAllMeansEverything() {
        XCTAssertEqual(doctorRequest(#"{"verb":"doctor","all":true}"#)?.scope, .everything)
    }

    func testNamedAppsBeatAll() {
        let request = doctorRequest(#"{"verb":"doctor","all":true,"apps":["com.a.b"]}"#)
        XCTAssertEqual(request?.scope, .only(["com.a.b"]))
    }

    func testDoctorNotifyIsCarried() {
        XCTAssertEqual(doctorRequest(#"{"verb":"doctor","notify":true}"#)?.notify, true)
    }

    // MARK: - The doctor CLI

    private func parse(_ args: [String]) -> TrillCLI.DoctorInvocation? {
        guard case .success(let invocation) = TrillCLI.parseDoctor(args) else { return nil }
        return invocation
    }

    func testCLIDoctorDefaultsToAskingTheDaemon() {
        let invocation = parse([])
        XCTAssertNil(invocation?.request.apps)
        XCTAssertNil(invocation?.request.all)
        XCTAssertNil(invocation?.request.notify)
        XCTAssertEqual(invocation?.json, false)
    }

    func testCLIDoctorFlagsAndBundleIDs() {
        let invocation = parse(["--all", "--notify", "--json", "com.a.b"])
        XCTAssertEqual(invocation?.request.apps, ["com.a.b"])
        XCTAssertEqual(invocation?.request.all, true)
        XCTAssertEqual(invocation?.request.notify, true)
        XCTAssertEqual(invocation?.json, true)
    }

    func testCLIDoctorRefusesUnknownFlags() {
        guard case .failure = TrillCLI.parseDoctor(["--fix-it-for-me"]) else {
            return XCTFail("expected a parse failure")
        }
    }
}
