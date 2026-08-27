import XCTest
@testable import Trill

/// The menu row and `trill report` are one shape by two routes, and both of
/// them can fail in ways nothing notices: a URL that opens the *blank* editor
/// instead of the form, or a block that arrives at GitHub subtly rewritten.
/// Neither throws. These pin both.
final class BugReportTests: XCTestCase {

    // MARK: - The template is the whole point
    //
    // A `?body=` prefill opens GitHub's blank editor and walks past the form —
    // its fields, its "wrong repo? file it anyway" preamble, its labels.
    // Nothing fails; the reporter just never sees any of it.

    func testTheURLNamesTheTemplate() {
        let url = BugReport.destination(diagnostics: "trill dev").url
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "template" }?.value, "bug.yml")
    }

    func testTheBlockRidesInTheQueryRatherThanThePasteboard() {
        let destination = BugReport.destination(diagnostics: "trill 2026.08.25")
        XCTAssertNil(destination.pasteboard)
        let query = URLComponents(url: destination.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "diagnostics" }?.value, "trill 2026.08.25")
    }

    // MARK: - Encoding
    //
    // `URLComponents.queryItems` encodes with `CharacterSet.urlQueryAllowed`,
    // which CONTAINS `+` — so it leaves it literal, and a literal `+` in a
    // query decodes as a SPACE at the far end. Hand-rolled strict encoding is
    // the fix; these are what keep it honest.

    func testAPlusIsEncodedRatherThanArrivingAsASpace() {
        let url = BugReport.destination(diagnostics: "shortcut cmd+space").url.absoluteString
        XCTAssertTrue(url.contains("cmd%2Bspace"), url)
        XCTAssertFalse(url.contains("cmd+space"), url)
    }

    func testAnAmpersandCannotStartASecondParameter() {
        let url = BugReport.destination(diagnostics: "a&template=nope").url
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.count, 2)
        XCTAssertEqual(query.first { $0.name == "template" }?.value, "bug.yml")
        XCTAssertEqual(query.first { $0.name == "diagnostics" }?.value, "a&template=nope")
    }

    func testNewlinesAndNonASCIISurviveTheRoundTrip() {
        let block = "trill 2026.08.25\nmacOS 26.0.1 (25A354)\nFull Disk Access: granted ✓"
        let url = BugReport.destination(diagnostics: block).url
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "diagnostics" }?.value, block)
    }

    // MARK: - The length guard
    //
    // GitHub refuses a URL past roughly 8 KB. trill's block is ~120 bytes, so
    // this is a guard rail rather than a live path — it exists so the day
    // someone adds a rule dump or a log tail here, the door still opens a form
    // instead of a server error.

    func testAnOverlongBlockFallsBackToThePasteboardWithTheFormStillOpening() {
        let huge = String(repeating: "x", count: BugReport.maximumURLLength + 1)
        let destination = BugReport.destination(diagnostics: huge)
        XCTAssertEqual(destination.pasteboard, huge)
        XCTAssertLessThanOrEqual(destination.url.absoluteString.count, BugReport.maximumURLLength)
        let query = URLComponents(url: destination.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "template" }?.value, "bug.yml")
        XCTAssertNil(query.first { $0.name == "diagnostics" })
    }

    // MARK: - What lands in a public issue
    //
    // A reporter reads this before pressing Submit, but they read it in a field
    // the app filled in for them — which is a weaker kind of consent than
    // typing it. So: no paths, no usernames, nothing off their inbox.

    func testTheBlockIsFiveLinesAndNamesWhatWasObserved() {
        XCTAssertEqual(
            BugReport.diagnostics(
                version: "2026.08.25",
                operatingSystem: "26.0.1 (25A354)",
                model: "Mac16,10",
                install: .homebrew,
                settingsStore: .readable
            ),
            """
            trill 2026.08.25
            macOS 26.0.1 (25A354)
            Mac16,10
            installed: Homebrew cask
            Full Disk Access: granted (notification settings readable)
            """
        )
    }

    /// The unreadable case must NOT read as a verdict on the grant.
    ///
    /// `unreadableReason()` is nil-or-not on a read that fails for either
    /// reason — grant missing, or the store absent/reshaped. "Full Disk
    /// Access: not granted" would be a wrong answer printed confidently, on
    /// the exact report class where the grant is the commonest right answer.
    /// Same collapse AGENTS.md forbids the audit itself.
    func testAnUnreadableStoreIsNotReportedAsADeniedGrant() {
        let line = BugReport.SettingsStoreReading.unreadable.description
        XCTAssertFalse(line.contains("not granted"), line)
        XCTAssertTrue(line.contains("unreadable"), line)
        XCTAssertTrue(line.contains("Full Disk Access"), "…while still naming the likeliest cause")
    }

    func testTheLiveBlockCarriesNoHomeDirectory() {
        let block = BugReport.diagnostics()
        XCTAssertFalse(block.contains(NSHomeDirectory()), block)
        XCTAssertFalse(block.contains("/Users/"), block)
    }

    // MARK: - Where this copy came from
    //
    // A cask's `app` stanza MOVES the bundle to /Applications, so the path
    // alone cannot tell a cask copy from a dragged one.

    func testTheCaskReceiptBreaksTheTieAtTheSharedApplicationsPath() {
        XCTAssertEqual(
            BugReport.InstallLocation.detect(
                bundlePath: "/Applications/Trill.app",
                home: "/Users/x",
                hasCaskReceipt: true
            ),
            .homebrew
        )
        XCTAssertEqual(
            BugReport.InstallLocation.detect(
                bundlePath: "/Applications/Trill.app",
                home: "/Users/x",
                hasCaskReceipt: false
            ),
            .applications
        )
    }

    func testAStorePathIsNixEvenWithACaskReceiptLyingAround() {
        // A Mac can have both: brew installed trill once, the flake installs it
        // now. What is RUNNING is the store path, and that is the question.
        XCTAssertEqual(
            BugReport.InstallLocation.detect(
                bundlePath: "/nix/store/abc-trill-2026.08.25/Applications/Trill.app",
                home: "/Users/x",
                hasCaskReceipt: true
            ),
            .nix
        )
    }

    func testAUserApplicationsCopyIsNotReportedAsSlashApplications() {
        XCTAssertEqual(
            BugReport.InstallLocation.detect(
                bundlePath: "/Users/x/Applications/Trill.app",
                home: "/Users/x",
                hasCaskReceipt: false
            ),
            .userApplications
        )
    }

    func testEveryLocationHasAWordingThatSaysSomething() {
        for location in BugReport.InstallLocation.allCases {
            XCTAssertFalse(location.description.isEmpty)
        }
    }

    // MARK: - The CLI half

    func testReportIsASubcommandSoTheBinaryDoesNotLaunchTheDaemonForIt() {
        // TrillMain routes on this set: a verb missing from it starts the
        // compositor instead of running the command, which for `trill report`
        // would mean a second copy of the app rather than a browser tab.
        XCTAssertTrue(TrillCLI.subcommands.contains("report"))
    }

    func testReportRejectsUnknownFlagsWithTheOrdinaryUsageCode() {
        // Not 64. `AskExit`'s 64/69/70/75 belong to `ask` alone — they exist
        // because `ask` spends 0,1,2 on which pill was pressed. Every other
        // verb answers 1 for bad usage, and `report` is every other verb.
        XCTAssertEqual(TrillCLI.runReport(["--bogus"]), 1)
        XCTAssertNotEqual(TrillCLI.runReport(["--bogus"]), 64)
    }

    func testHelpMentionsReport() {
        XCTAssertTrue(TrillCLI.usage.contains("trill report"), "usage is the only place the verb is discoverable")
    }
}
