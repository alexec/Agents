import Foundation

/// Asking git what changed, without touching the repository (035 research R4).
///
/// An agent may be committing in the same repository at the same moment, so nothing
/// here may take a lock it could collide with or write an index it did not ask for.
/// `git status` is the command that quietly refreshes the index; `GIT_OPTIONAL_LOCKS=0`
/// is git's own switch for a reader that must not, and every command here runs with it.
/// The flags on every diff make the answer the same whatever the person's config says:
/// no external diff tool, no text conversion, no colour, no rename guessing.
public enum GitChanges {
    /// Laid over `GitProcess`'s environment for every command here.
    static let readOnly = ["GIT_OPTIONAL_LOCKS": "0"]
    static let diffFlags = ["--no-ext-diff", "--no-textconv", "--no-color", "--no-renames"]

    public enum Failure: Error, Sendable, Equatable {
        case notInstalled
        /// git said no, in its own words.
        case refused(String)
    }

    /// One read-only git command, run in `folder`.
    static func run(_ arguments: [String], in folder: URL, input: Data? = nil) async throws -> GitProcess.Outcome {
        let git: GitProcess
        do {
            git = try GitProcess(["-c", "core.quotepath=off"] + arguments, in: folder,
                                 environment: readOnly, input: input)
        } catch {
            throw Failure.notInstalled
        }
        let outcome = try await git.run()
        guard outcome.succeeded else {
            throw Failure.refused(outcome.errors.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return outcome
    }

    /// The repository and the commit a folder is on, or nil when it is not in a
    /// repository, the repository has no commits, or git is not there. Never throws:
    /// an agent starts whether or not its changes can be measured.
    public static func startingPoint(of folder: URL) async -> StartingPoint? {
        guard let outcome = try? await run(["rev-parse", "--show-toplevel", "HEAD"], in: folder)
        else { return nil }
        let lines = outcome.output.split(separator: "\n").map(String.init)
        guard lines.count == 2, lines[1].count >= 40 else { return nil }
        return StartingPoint(repository: URL(filePath: lines[0], directoryHint: .isDirectory),
                             commit: lines[1])
    }

    /// The top of the repository a folder is in.
    static func repositoryRoot(of folder: URL) async throws -> URL {
        let outcome = try await run(["rev-parse", "--show-toplevel"], in: folder)
        return URL(filePath: outcome.output.trimmingCharacters(in: .whitespacesAndNewlines),
                   directoryHint: .isDirectory)
    }

    // MARK: What changed

    /// One file git sees changed, relative to the repository's top.
    struct Changed: Equatable, Sendable {
        var path: String
        var status: Character
        /// Nil for binary.
        var added: Int?
        var removed: Int?
    }

    /// Every tracked file that differs from `since` in the working tree, and every
    /// untracked file git does not ignore, under `scope` (a path relative to the top,
    /// or nil for all of it).
    static func changed(since: String, in root: URL, scope: String?) async throws -> [Changed] {
        let pathspec = ["--"] + (scope.map { [$0] } ?? [])
        async let numbers = run(["diff", "--numstat", "-z"] + diffFlags + [since] + pathspec, in: root)
        async let statuses = run(["diff", "--name-status", "-z"] + diffFlags + [since] + pathspec, in: root)
        async let others = run(["ls-files", "--others", "--exclude-standard", "-z"] + pathspec, in: root)
        let counted = parseNumstat(try await numbers.data)
        let status = parseNameStatus(try await statuses.data)
        var changed = status.map { path, code in
            Changed(path: path, status: code,
                    added: counted[path].flatMap { $0.added },
                    removed: counted[path].flatMap { $0.removed })
        }
        for path in split(try await others.data) {
            changed.append(Changed(path: path, status: "?", added: nil, removed: nil))
        }
        return changed
    }

    /// `--numstat -z`: `added\tremoved\tpath\0`, with `-` for both on a binary file.
    static func parseNumstat(_ data: Data) -> [String: (added: Int?, removed: Int?)] {
        var counts: [String: (added: Int?, removed: Int?)] = [:]
        for record in split(data) {
            let fields = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            counts[String(fields[2])] = (Int(fields[0]), Int(fields[1]))
        }
        return counts
    }

    /// `--name-status -z`: the status letter and the path, each ended by a NUL.
    static func parseNameStatus(_ data: Data) -> [(path: String, status: Character)] {
        let fields = split(data)
        var result: [(String, Character)] = []
        var index = 0
        while index + 1 < fields.count {
            result.append((fields[index + 1], fields[index].first ?? "M"))
            index += 2
        }
        return result
    }

    static func split(_ data: Data) -> [String] {
        data.split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    // MARK: Text at the starting point

    /// Each file's text at `commit`, read in one `cat-file --batch`. A file that was not
    /// there then is absent from the answer.
    static func texts(of paths: [String], at commit: String, in root: URL) async throws -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        let request = paths.map { "\(commit):\($0)\n" }.joined()
        let outcome = try await run(["cat-file", "--batch"], in: root, input: Data(request.utf8))
        return parseBatch(outcome.data, paths: paths)
    }

    /// `<sha> <type> <size>\n<bytes>\n` per object found, `<name> missing\n` otherwise,
    /// in the order asked.
    static func parseBatch(_ data: Data, paths: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var cursor = data.startIndex
        for path in paths {
            guard let newline = data[cursor...].firstIndex(of: 0x0A) else { break }
            let header = String(decoding: data[cursor..<newline], as: UTF8.self)
            cursor = data.index(after: newline)
            let fields = header.split(separator: " ")
            guard fields.count == 3, let size = Int(fields[2]) else { continue }
            let end = data.index(cursor, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            if fields[1] == "blob" { result[path] = String(decoding: data[cursor..<end], as: UTF8.self) }
            cursor = end < data.endIndex ? data.index(after: end) : end
        }
        return result
    }

    // MARK: One file

    /// The whole of a tracked file as it now stands against `since`, every line there
    /// with removed lines in place. Nil for binary.
    static func whole(of path: String, since: String, in root: URL) async throws -> [DiffLine]? {
        let outcome = try await run(["diff", "-U999999"] + diffFlags + [since, "--", path], in: root)
        if outcome.output.contains("\nBinary files ") || outcome.output.hasPrefix("Binary files ") {
            return nil
        }
        let hunks = parseUnified(outcome.output)
        if hunks.isEmpty {
            // Nothing differs: the file as it is, every line context.
            guard let text = try? String(contentsOf: root.appending(path: path), encoding: .utf8)
            else { return nil }
            return allLines(of: text, as: .context)
        }
        return hunks.flatMap(\.lines)
    }

    /// Every line of a text, as one kind: an untracked file is all added.
    static func allLines(of text: String, as kind: DiffLine.Kind) -> [DiffLine] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines.enumerated().map { DiffLine(kind: kind, text: $1, newLine: $0 + 1) }
    }

    /// A unified diff's hunks. Everything before the first `@@` is headers.
    static func parseUnified(_ text: String) -> [FolderHunk] {
        var hunks: [FolderHunk] = []
        var newLine = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                let (oldStart, newStart) = hunkStarts(line)
                hunks.append(FolderHunk(oldStart: oldStart, newStart: newStart, lines: []))
                newLine = newStart
                continue
            }
            guard !hunks.isEmpty, let mark = line.first else { continue }
            let body = String(line.dropFirst())
            switch mark {
            case " ":
                hunks[hunks.count - 1].lines.append(DiffLine(kind: .context, text: body, newLine: newLine))
                newLine += 1
            case "+":
                hunks[hunks.count - 1].lines.append(DiffLine(kind: .added, text: body, newLine: newLine))
                newLine += 1
            case "-":
                hunks[hunks.count - 1].lines.append(DiffLine(kind: .removed, text: body))
            case "\\":
                hunks[hunks.count - 1].noNewlineAtEnd = true
            default:
                continue
            }
        }
        return hunks
    }

    /// `@@ -a[,b] +c[,d] @@` → (a, c).
    static func hunkStarts(_ header: String) -> (Int, Int) {
        let parts = header.split(separator: " ")
        func start(_ prefix: Character) -> Int {
            guard let part = parts.first(where: { $0.first == prefix }) else { return 0 }
            return Int(part.dropFirst().split(separator: ",").first ?? "") ?? 0
        }
        return (start("-"), start("+"))
    }
}
