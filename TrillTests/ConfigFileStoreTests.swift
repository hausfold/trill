import XCTest
@testable import Trill

/// The settings file is the source of truth, which makes these the tests that
/// say what "source of truth" actually means: a partial file is normal, a
/// broken one changes nothing, a write keeps what trill didn't write, and an
/// edit made while trill runs reaches the app.
final class ConfigFileStoreTests: XCTestCase {
    private var directory: URL!
    private var file: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trill-config-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("config.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ json: String) throws {
        try json.write(to: file, atomically: true, encoding: .utf8)
    }

    private func contents() throws -> [String: Any] {
        let data = try Data(contentsOf: file)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testNoFileMeansEverySettingIsAtItsDefault() {
        let store = ConfigFileStore(file: file)
        XCTAssertEqual(store.current(), AppConfig())
    }

    func testAPartialFileLeavesTheRestAtTheirDefaults() throws {
        try write(#"{ "persistHistory": false }"#)
        let store = ConfigFileStore(file: file)
        XCTAssertFalse(store.current().persistHistory)
        XCTAssertTrue(store.current().launchAtLogin, "a key the file doesn't name is that key's default")
        XCTAssertEqual(store.namedKeys(), ["persistHistory"])
    }

    func testAWriteNamesEverySettingSoTheFileIsSelfDocumenting() throws {
        let store = ConfigFileStore(file: file)
        XCTAssertNil(store.update { $0.githubBridgeEnabled = true })
        let json = try contents()
        XCTAssertEqual(json[AppConfig.Key.githubBridge] as? Bool, true)
        XCTAssertEqual(json.keys.count, AppConfig().json.keys.count,
                       "every switch is written, not just the changed one")
    }

    /// The default is "whatever macOS is using", which is an empty string
    /// rather than a family name — and it is written like every other switch,
    /// so opening the file shows you the key you were looking for.
    func testTheProportionalFamilyIsEmptyUntilSomebodyNamesOne() throws {
        XCTAssertEqual(ConfigFileStore(file: file).current().fontFamily, "")
        try write(#"{ "fontFamily": "Atkinson Hyperlegible" }"#)
        XCTAssertEqual(ConfigFileStore(file: file).current().fontFamily, "Atkinson Hyperlegible")
    }

    func testShynessIsOnUnlessTheFileSaysOtherwise() throws {
        XCTAssertTrue(ConfigFileStore(file: file).current().shyWhenWatched,
                      "a privacy default that has to be switched on is a default nobody has on")
        try write(#"{ "shyWhenWatched": false }"#)
        XCTAssertFalse(ConfigFileStore(file: file).current().shyWhenWatched)
    }

    // MARK: - Which apps the mirror draws

    /// The one key whose *absence* is a value: nobody has picked, so the
    /// mirror draws everything. Writing it as `[]` would turn "not chosen"
    /// into "chosen: none" the first time any unrelated switch moved.
    func testTheMirrorAppListIsAbsentUntilSomebodyPicksOne() throws {
        let store = ConfigFileStore(file: file)
        XCTAssertNil(store.current().systemMirrorApps)
        XCTAssertNil(store.update { $0.persistHistory = false })
        XCTAssertNil(try contents()[AppConfig.Key.systemMirrorApps],
                     "an unchosen list is a key the file doesn't name")
    }

    func testAnEmptyMirrorListIsAChoiceAndSurvivesAWrite() throws {
        let store = ConfigFileStore(file: file)
        XCTAssertNil(store.update { $0.systemMirrorApps = [] })
        XCTAssertEqual(try contents()[AppConfig.Key.systemMirrorApps] as? [String], [])
        XCTAssertEqual(ConfigFileStore(file: file).current().systemMirrorApps, [],
                       "unticking the last app means none, not all of them again")
    }

    func testMirroringEveryAppAgainRemovesTheKey() throws {
        try write(#"{ "systemMirrorApps": ["com.foo.bar"] }"#)
        let store = ConfigFileStore(file: file)
        XCTAssertEqual(store.current().systemMirrorApps, ["com.foo.bar"])
        XCTAssertNil(store.update { $0.systemMirrorApps = nil })
        XCTAssertNil(try contents()[AppConfig.Key.systemMirrorApps],
                     "going back to every app has to clear the key, not blank it")
    }

    func testAHandWrittenMirrorListIsMatchedTheWayRulesAre() throws {
        try write(#"{ "systemMirrorApps": ["com.apple.MobileSMS"] }"#)
        XCTAssertEqual(ConfigFileStore(file: file).current().systemMirrorApps,
                       ["com.apple.mobilesms"])
    }

    func testAMistypedMirrorListReadsAsUnchosenRatherThanEmpty() throws {
        try write(#"{ "systemMirrorApps": "com.foo.bar" }"#)
        XCTAssertNil(ConfigFileStore(file: file).current().systemMirrorApps,
                     "a typo must not silently mirror nothing")
    }

    /// The first untick has nothing to remove from, so it writes down what it
    /// is narrowing from — every app the store knows, not just the rows the
    /// pane happened to be showing.
    func testTheFirstUntickWritesDownEveryAppItIsNarrowingFrom() {
        let list = AppConfig.mirrorList(
            nil, setting: false, for: "com.tinyspeck.slackmacgap",
            everyKnownApp: ["com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "com.apple.clock"]
        )
        XCTAssertEqual(list, ["com.apple.clock", "com.apple.mobilesms"])
    }

    func testTickingAnAppAddsItToAnExistingList() {
        let list = AppConfig.mirrorList(
            ["com.apple.mobilesms"], setting: true, for: "com.tinyspeck.SlackMacGap",
            everyKnownApp: []
        )
        XCTAssertEqual(list, ["com.apple.mobilesms", "com.tinyspeck.slackmacgap"])
    }

    func testUntickingTheLastAppLeavesAnEmptyListNotAnAbsentOne() {
        let list = AppConfig.mirrorList(
            ["com.apple.mobilesms"], setting: false, for: "com.apple.mobilesms",
            everyKnownApp: ["com.apple.mobilesms", "com.tinyspeck.slackmacgap"]
        )
        XCTAssertEqual(list, [], "an existing list narrows to nothing — it does not reset to all")
    }

    func testAWriteKeepsKeysTrillDoesNotKnow() throws {
        try write(#"{ "somethingNewer": 42, "persistHistory": false }"#)
        let store = ConfigFileStore(file: file)
        XCTAssertNil(store.update { $0.launchAtLogin = false })
        XCTAssertEqual(try contents()["somethingNewer"] as? Int, 42)
        XCTAssertEqual(try contents()[AppConfig.Key.persistHistory] as? Bool, false,
                       "and the setting it wasn't asked to change")
    }

    func testAWriteThatChangesNothingIsNotAWrite() throws {
        let store = ConfigFileStore(file: file)
        XCTAssertNil(store.update { $0.launchAtLogin = AppConfig().launchAtLogin })
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "no file is created for a change that isn't one")
    }

    func testAMalformedFileKeepsThePreviousSettings() throws {
        try write(#"{ "persistHistory": false }"#)
        let store = ConfigFileStore(file: file)
        let expectation = expectation(description: "the store notices the file")
        expectation.isInverted = true
        store.start { _ in expectation.fulfill() }

        try write("{ this is not json")
        wait(for: [expectation], timeout: 1.5)
        XCTAssertFalse(store.current().persistHistory, "a typo must not turn a setting back on")
    }

    func testAnEditWhileTrillRunsReachesTheApp() throws {
        try write(#"{ "persistHistory": true }"#)
        let store = ConfigFileStore(file: file)
        let changed = expectation(description: "onChange fires with the edited value")
        store.start { config in
            if !config.persistHistory { changed.fulfill() }
        }

        try write(#"{ "persistHistory": false }"#)
        wait(for: [changed], timeout: 5)
        XCTAssertFalse(store.current().persistHistory)
    }

    /// The bug this is here for: the watcher re-arms after every write, and an
    /// implementation that closes its own descriptor while re-arming stops
    /// noticing edits after the *first* toggle — which is exactly the moment
    /// nobody re-tests by hand.
    func testTheWatcherStillFollowsTheFileAfterTrillWritesItItself() throws {
        let store = ConfigFileStore(file: file)
        let changed = expectation(description: "onChange fires after a self-write")
        store.start { config in
            if config.githubBridgeEnabled { changed.fulfill() }
        }

        XCTAssertNil(store.update { $0.launchAtLogin = false })
        try write(#"{ "githubBridge": true }"#)
        wait(for: [changed], timeout: 5)
    }
}
