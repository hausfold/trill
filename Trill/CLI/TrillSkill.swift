import Foundation

/// `trill skill` — A3 of the family agent surface (the workshop's
/// `docs/agent-surface.md`): the tool hands an agent its own instructions, so
/// somebody with trill installed and no checkout of this repo can say "teach my
/// agent trill" and have it work.
///
///     trill skill                 print trill's own SKILL.md
///     trill skill <name>          print one of the others (none today)
///     trill skill install         write ALL of them into every client found
///     trill skill install --client claude|codex|opencode|pi
///     trill skill install --dir PATH
///
/// **Who this is for.** On a haus machine the skills are already installed —
/// `modules/ai/tool-skills.nix` names `trill`, gated on
/// `haus.notifications.compositor` — so `install` there has nothing to do and
/// says so. The verb exists for the *standalone* user: a release ZIP dragged to
/// /Applications, with no layer to install anything on their behalf. `nix/skill.nix`
/// used to say this verb was unnecessary; it was, until that user existed.
///
/// **The prose is embedded, not read off disk** (`EmbeddedSkills`, generated
/// from `ai/` by `scripts/generate-skills.sh`). A cask ships an `.app`, a Nix
/// build ships a store path, a ZIP ships a bundle — only embedding is uniform
/// across all three, and it makes the version that answers `--help` the version
/// that answers `skill`. A `Bundle.main` lookup would also break the CLI
/// personality the moment somebody copied the binary out of the bundle.
extension TrillCLI {
    /// One skill as it shipped: the name a client routes on, and the bytes.
    struct EmbeddedSkill: Equatable, Sendable {
        let name: String
        /// `ai/…/SKILL.md` verbatim, minus its final newline — every writer
        /// here puts that back, so what lands on disk is the committed file.
        let body: String
    }

    /// Where each agent client reads its skills from. The layout inside is the
    /// same for all four — `<dir>/<skill name>/SKILL.md` — which is why only
    /// the directory differs. Same four ids scruff and factory use; one
    /// spelling across the family or a user has to learn ours.
    static let skillClients = ["claude", "codex", "opencode", "pi"]

    static func skillClientDirectory(_ client: String, home: URL) -> URL? {
        switch client {
        case "claude": home.appendingPathComponent(".claude/skills")
        case "codex": home.appendingPathComponent(".codex/skills")
        case "opencode": home.appendingPathComponent(".config/opencode/skills")
        case "pi": home.appendingPathComponent(".pi/agent/skills")
        default: nil
        }
    }

    static func runSkill(_ args: [String]) -> Int32 {
        if args.first == "install" {
            return runSkillInstall(Array(args.dropFirst()))
        }

        let name: String
        switch args.count {
        case 0: name = "trill"
        case 1 where !args[0].hasPrefix("-"): name = args[0]
        default:
            FileHandle.standardError.write(Data(
                "trill: usage: trill skill [<name>] | trill skill install [--client ID] [--dir PATH]\n".utf8
            ))
            return 1
        }

        guard let skill = EmbeddedSkills.all.first(where: { $0.name == name }) else {
            let names = EmbeddedSkills.all.map(\.name).joined(separator: ", ")
            FileHandle.standardError.write(Data(
                "trill: no skill named '\(name)' — trill ships: \(names)\n".utf8
            ))
            return 1
        }
        // Straight through, unformatted: a SKILL.md full of `%` in its
        // examples is not a format string, and this is data on stdout.
        print(skill.body)
        return 0
    }

    /// Writes **every** skill trill ships into every target. "Every" is the
    /// standard's word: a tool that ships a second skill and installs only its
    /// first reaches no standalone user with it.
    ///
    /// It never clobbers, and the two ways it declines are different answers.
    /// A file that exists and *differs* is somebody's edit, and a file it
    /// cannot write is a directory somebody else owns: both are the caller's
    /// request not honoured, named and left alone, and the run exits 3 so the
    /// caller learns it was only partly honoured. A path that is a **symlink**
    /// belongs to whatever manages the link — on a haus machine that is
    /// `haus.ai.skill`, pointing into a read-only Nix store, and writing
    /// through it would either revert on the next rebuild or fail with an
    /// `EPERM` the user has to decode. That is the end state holding, not a
    /// refusal: named, left alone, and a run that finds only links exits 0,
    /// because a non-zero there would have every agent on a normal haus
    /// machine report a broken command and retry with force. The three rules
    /// are A3 of the workshop's `docs/agent-surface.md`.
    static func runSkillInstall(_ args: [String], home: URL? = nil) -> Int32 {
        var directory: String?
        var client: String?

        var iterator = args.makeIterator()
        while let flag = iterator.next() {
            switch flag {
            case "--dir":
                // An empty value is an unset shell variable, not a request.
                // Falling through to discovery there would install into all
                // four real client directories while the caller believed it
                // was writing to a scratch path.
                guard let raw = iterator.next(), !raw.isEmpty else {
                    return skillUsage("--dir wants a path")
                }
                directory = raw
            case "--client":
                // The same unset-variable trap as --dir: let through, an
                // empty client reaches the table and is refused as "unknown
                // client" — true, and not the sentence for what the caller did.
                guard let raw = iterator.next(), !raw.isEmpty else {
                    return skillUsage("--client wants one of: \(skillClients.joined(separator: ", "))")
                }
                client = raw
            default:
                return skillUsage("unknown flag '\(flag)' — usage: trill skill install [--client ID] [--dir PATH]")
            }
        }

        // Two answers to "where", where only one can be honoured. Picking
        // silently would write somewhere the caller named a different path for.
        if directory != nil, client != nil {
            return skillUsage("--dir and --client both name a destination — pass one")
        }

        let root = home ?? FileManager.default.homeDirectoryForCurrentUser
        var targets: [URL] = []
        if let directory {
            targets = [URL(fileURLWithPath: directory)]
        } else if let client {
            guard let resolved = skillClientDirectory(client, home: root) else {
                return skillUsage("unknown client '\(client)' (expected \(skillClients.joined(separator: ", ")))")
            }
            targets = [resolved]
        } else {
            // Discovered, not assumed: a client's skills directory may not
            // exist yet, but its home does the moment the client has ever run.
            // Creating ~/.codex on a Mac with no codex would be trill
            // inventing a client rather than serving one.
            targets = skillClients.compactMap { skillClientDirectory($0, home: root) }
                .filter { FileManager.default.fileExists(atPath: $0.deletingLastPathComponent().path) }
        }
        guard !targets.isEmpty else {
            return skillUsage("no agent client found under \(root.path) — name one with --client, or a path with --dir")
        }

        var wrote = 0
        var current = 0
        // Counted apart from `left` because the two are opposite answers
        // wearing the same word: a symlink is the desired end state holding, a
        // file that differs is the request not honoured, and only the second
        // may reach the exit code.
        var managed = 0
        var left = 0
        for target in targets {
            for skill in EmbeddedSkills.all {
                let folder = target.appendingPathComponent(skill.name)
                let destination = folder.appendingPathComponent("SKILL.md")
                let body = Data((skill.body + "\n").utf8)

                // Either level, because haus installs the DIRECTORY as one
                // link into the store: checking only the file would write
                // straight through it.
                if isSymlink(folder) || isSymlink(destination) {
                    note("left alone \(destination.path) — a symlink, so something else manages it (on a haus machine, haus.ai.skill already did)")
                    managed += 1
                    continue
                }
                if let existing = FileManager.default.contents(atPath: destination.path) {
                    if existing == body {
                        current += 1
                        continue
                    }
                    note("left alone \(destination.path) — it exists and differs; compare it with: trill skill \(skill.name) | diff - \(destination.path)")
                    left += 1
                    continue
                }
                // A directory trill cannot write into is the same answer as a
                // symlink it must not write through, and it has to be
                // per-file: returning here would abandon the clients after
                // this one on a Mac whose *first* client directory is
                // read-only, and hand back the bare EPERM this verb exists to
                // replace with a sentence.
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try body.write(to: destination)
                } catch {
                    note("left alone \(destination.path) — cannot write it: \(error.localizedDescription)")
                    left += 1
                    continue
                }
                note("wrote \(destination.path)")
                wrote += 1
            }
        }

        // The whole run was somebody else's install holding. Say that in a
        // sentence rather than as a count of zero: nothing was asked for that
        // does not already exist.
        if wrote == 0, current == 0, left == 0, managed > 0 {
            note("nothing to install: every skill here is already a symlink something else manages (on a haus machine, haus.ai.skill)")
            note("to place a copy somewhere nothing else manages: trill skill install --dir <path>")
            return 0
        }
        note("skills: \(wrote) written, \(current) already current, \(managed) managed elsewhere, \(left) left alone")
        // Non-zero so a caller learns its request was only partly honoured —
        // "3 refused" reads the same here as it does for the daemon: trill
        // understood and declined. Only `left` counts: a symlink was never
        // this verb's file to write.
        return left > 0 ? 3 : 0
    }

    /// Lstat, not stat: `attributesOfItem` stops at the link rather than
    /// following it, which is the only reading that can tell "haus put a store
    /// path here" from "there is a file here".
    private static func isSymlink(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return false }
        return attributes[.type] as? FileAttributeType == .typeSymbolicLink
    }

    /// Progress goes to stderr, always: `trill skill` puts a document on
    /// stdout, and `install` must not teach a caller that this verb sometimes
    /// prints prose there instead.
    private static func note(_ message: String) {
        FileHandle.standardError.write(Data("trill: \(message)\n".utf8))
    }

    private static func skillUsage(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("trill: \(message)\n".utf8))
        return 1
    }
}
