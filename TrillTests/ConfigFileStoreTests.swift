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
        XCTAssertEqual(json.keys.count, 4, "all four switches are written, not just the changed one")
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
