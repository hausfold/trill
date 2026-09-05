import XCTest
@testable import Trill

/// `trill skill` — A3 of the family agent surface.
///
/// The prose itself is guarded by `scripts/check-skills.sh`, which CI runs
/// before the build and `nix/skill.nix` runs over the same files. What is
/// tested here is the half a shell script can't see: that the bytes really are
/// *in this binary*, and that `install` refuses in the two ways it has to
/// rather than clobbering somebody's file or writing through a Nix symlink.
final class SkillVerbTests: XCTestCase {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trill-skill-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTheSkillShippedInsideThisBinary() throws {
        let trill = try XCTUnwrap(
            TrillCLI.EmbeddedSkills.all.first { $0.name == "trill" },
            "trill must ship its own skill — a tool that can't hand an agent its instructions has none"
        )
        XCTAssertTrue(
            trill.body.hasPrefix("---\nname: trill\n"),
            "frontmatter first, or every client installs it and none loads it"
        )
        XCTAssertTrue(trill.body.contains("description: "))
        XCTAssertFalse(
            trill.body.hasSuffix("\n"),
            "the literal drops the file's final newline; every writer here puts exactly one back"
        )
    }

    func testEverySkillIsNamedForTheDirectoryItInstallsInto() {
        for skill in TrillCLI.EmbeddedSkills.all {
            XCTAssertTrue(
                skill.body.contains("\nname: \(skill.name)\n"),
                "\(skill.name): the path a client scans and the string it routes on are one skill"
            )
        }
    }

    func testInstallWritesEverySkillThenLeavesItAlone() throws {
        let target = try scratch()

        XCTAssertEqual(TrillCLI.runSkillInstall(["--dir", target.path]), 0)
        for skill in TrillCLI.EmbeddedSkills.all {
            let written = target.appendingPathComponent("\(skill.name)/SKILL.md")
            let bytes = try XCTUnwrap(FileManager.default.contents(atPath: written.path))
            XCTAssertEqual(
                String(decoding: bytes, as: UTF8.self), skill.body + "\n",
                "what lands on disk is the committed file, newline included"
            )
        }

        XCTAssertEqual(
            TrillCLI.runSkillInstall(["--dir", target.path]), 0,
            "a second run finds them current — installing twice is not a refusal"
        )
    }

    func testAFileThatDiffersIsLeftAloneAndTheRunSaysSo() throws {
        let target = try scratch()
        let folder = target.appendingPathComponent("trill")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("someone's own notes\n".utf8).write(to: folder.appendingPathComponent("SKILL.md"))

        XCTAssertEqual(
            TrillCLI.runSkillInstall(["--dir", target.path]), 3,
            "refused, not silently honoured — a caller has to learn its request only partly landed"
        )
        XCTAssertEqual(
            try String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8),
            "someone's own notes\n"
        )
    }

    func testASymlinkedSkillIsSomebodyElsesToManage() throws {
        // What a haus machine looks like: `haus.ai.skill` links the whole
        // directory at a read-only Nix store path. Writing through it would
        // either revert on the next rebuild or hand the user a bare EPERM.
        let target = try scratch()
        let elsewhere = try scratch()
        try FileManager.default.createSymbolicLink(
            at: target.appendingPathComponent("trill"), withDestinationURL: elsewhere
        )

        XCTAssertEqual(
            TrillCLI.runSkillInstall(["--dir", target.path]), 0,
            "the link is somebody else's install holding — the end state, not a refusal; a 3 here has every agent on a haus machine retry with force"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("SKILL.md").path),
            "nothing may be written through the link"
        )
    }

    func testTheWaysInstallRefusesToGuessWhere() throws {
        XCTAssertEqual(TrillCLI.runSkillInstall(["--dir", ""]), 1, "an empty --dir is an unset variable")
        XCTAssertEqual(TrillCLI.runSkillInstall(["--client", ""]), 1, "and so is an empty --client")
        XCTAssertEqual(TrillCLI.runSkillInstall(["--dir"]), 1, "a flag with nothing after it is usage, not a silent exit")
        XCTAssertEqual(TrillCLI.runSkillInstall(["--client"]), 1)
        XCTAssertEqual(TrillCLI.runSkillInstall(["--dir", "/tmp", "--client", "claude"]), 1)
        XCTAssertEqual(TrillCLI.runSkillInstall(["--client", "emacs"]), 1)
        XCTAssertEqual(TrillCLI.runSkillInstall(["--wat"]), 1)
        XCTAssertEqual(
            TrillCLI.runSkillInstall([], home: try scratch()), 1,
            "a home with no agent client is a usage error naming the flag that would have answered"
        )
    }

    func testEveryClientIsAKnownDirectory() {
        let home = URL(fileURLWithPath: "/Users/nobody")
        for client in TrillCLI.skillClients {
            XCTAssertNotNil(TrillCLI.skillClientDirectory(client, home: home), client)
        }
        XCTAssertNil(TrillCLI.skillClientDirectory("emacs", home: home))
    }

    func testAskingForASkillTrillDoesNotShip() {
        XCTAssertEqual(TrillCLI.runSkill(["nope"]), 1)
        XCTAssertEqual(TrillCLI.runSkill(["--json"]), 1, "no flags on the print form yet")
        XCTAssertEqual(TrillCLI.runSkill([]), 0)
    }
}
