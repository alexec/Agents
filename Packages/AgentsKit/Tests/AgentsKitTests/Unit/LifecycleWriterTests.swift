import Foundation
import Testing

/// SC-009: the number of places in this app that can write an agent's state is one.
///
/// A source scan, because that is the only honest way to check a claim about where
/// code *may* write — no assertion from inside the program can see a line that does
/// not exist yet. There is precedent: `ConsistencyTests` scans `App/Sources` and
/// `Remote/Sources` for the same kind of rule, and for the same reason.
///
/// The matcher is a pure function and is proved against samples below, rather than by
/// adding a real direct write and watching the scan fail. A scan that matches nothing
/// is a green test protecting nothing, so it has to be proved to bite — but proving it
/// by editing the repository leaves the edit behind the one time something interrupts
/// between breaking and restoring.
@Suite("Only a transition writes the state")
struct LifecycleWriterTests {
    /// The repository root, found from this file rather than from the working
    /// directory, so the check runs the same under `swift test` and under Xcode.
    private static let root = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private struct Source {
        let path: String
        let lines: [String]
    }

    private static func sources(under directory: String) throws -> [Source] {
        var found: [Source] = []
        let base = root.appending(path: directory)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
            return []
        }
        while let url = walker.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            found.append(Source(path: String(url.path.dropFirst(root.path.count + 1)),
                                lines: text.components(separatedBy: "\n")))
        }
        return found.sorted { $0.path < $1.path }
    }

    private static func code(_ line: String) -> Substring {
        if let range = line.range(of: "//") { return line[..<range.lowerBound] }
        return line[...]
    }

    /// Whether this line assigns to an **agent's** `state`.
    ///
    /// Deliberately narrow about what an agent is. `RuntimeAccount` and the shell host
    /// both have a `state` of their own and are nothing to do with the lifecycle, so
    /// the receiver has to look like an agent rather than merely have the property.
    static func writesAnAgentState(_ line: String) -> Bool {
        let code = code(line).trimmingCharacters(in: .whitespaces)
        guard let range = code.range(of: ".state = ") else { return false }
        let receiver = String(code[code.startIndex..<range.lowerBound])
            .replacingOccurrences(of: "self.", with: "")
        // `account.state`, `session.state`, `plan.state` and friends are other things
        // entirely. An agent is called one.
        let agentish = ["agent", "updated", "copy", "fixed", "mended", "found", "existing"]
        return agentish.contains { receiver.lowercased().hasSuffix($0) }
    }

    /// The matcher, against lines that must and must not trip it. This is what makes
    /// the scan below worth trusting.
    @Test func theScanCatchesADirectWriteAndNothingElse() {
        #expect(Self.writesAnAgentState("        agent.state = .stopped"))
        #expect(Self.writesAnAgentState("        updated.state = .stopped"))
        #expect(Self.writesAnAgentState("            self.agent.state = next"))
        #expect(Self.writesAnAgentState("        copy.state = .archived"))
        // Other things that happen to have a state.
        #expect(!Self.writesAnAgentState("        account.state = .ready"))
        #expect(!Self.writesAnAgentState("            self.state = state"))
        #expect(!Self.writesAnAgentState("        plan.state = .withdrawn"))
        // Reads, comparisons and comments are not writes.
        #expect(!Self.writesAnAgentState("        if agent.state == .stopped {"))
        #expect(!Self.writesAnAgentState("        // agent.state = .stopped"))
        #expect(!Self.writesAnAgentState("        let s = agent.state"))
    }

    /// Writes that are not lifecycle transitions, each with its reason.
    ///
    /// One entry, and it took an argument to earn. `AgentStore.mended` repairs a
    /// record that the four invariants forbid — `stopped` with no reason, `finished`
    /// that did not end in `endTurn`, and so on. It cannot go through the transition
    /// table, because the table is total over *events that happen to an agent* and
    /// "this record was already wrong when we read it" is not one of them; there is no
    /// event for it and inventing one would put a lie in the transcript.
    ///
    /// It is safe for the reason the funnel exists: the funnel governs an agent the
    /// daemon is holding, and this runs on a freshly decoded record before it is one.
    /// Nothing is watching it, nothing has been told about it, and the very next thing
    /// that happens is `loadFromDisk` announcing the mend in the transcript.
    ///
    /// SC-009 says "one place", and after this feature the honest count is **one
    /// transition writer plus the record mender**. That is worth saying out loud
    /// rather than hiding behind a looser regex.
    static let allowed: [(file: String, why: String)] = [
        (file: "Packages/AgentsKit/Sources/AgentsKit/Store/AgentStore.swift",
         why: "mends a record the invariants forbid, before it is an agent anything holds (FR-020)"),
    ]

    /// One transition writer, and it is the apply inside `move`.
    ///
    /// It was two until 020 closed the recovery bypass: `DaemonCore+Recovery` wrote
    /// `updated.state = .stopped` by hand, which is how an ending discovered on a
    /// restart came to skip the transcript, the counts and every workflow trigger.
    @Test func anAgentsStateIsWrittenInExactlyOnePlace() throws {
        var writes: [String] = []
        var allowedWrites = 0
        var scanned = 0
        for source in try Self.sources(under: "Packages/AgentsKit/Sources") {
            scanned += 1
            for (index, line) in source.lines.enumerated() where Self.writesAnAgentState(line) {
                if Self.allowed.contains(where: { source.path.hasSuffix($0.file) }) {
                    allowedWrites += 1
                    continue
                }
                writes.append("\(source.path):\(index + 1): \(Self.code(line).trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(scanned > 30, "too few sources were read; the repository root is wrong")
        #expect(writes.count == 1, """
            An agent's state is written in \(writes.count) places outside the \
            allow-list. It must be written in exactly one — the apply inside \
            `DaemonCore.move` — because every consequence of a state change hangs off \
            that function: the record before the windows, the transcript line, the \
            project's counts and the workflow triggers. A direct write gets none of \
            them, and gets them silently. If a new write is genuinely not a lifecycle \
            transition, add it to `allowed` with its reason.
            \(writes.joined(separator: "\n"))
            """)
        #expect(writes.first?.hasPrefix("Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift") == true,
                "the one writer moved: \(writes.first ?? "none")")
        // The allow-list is not a place things drift into unnoticed.
        #expect(allowedWrites == 2, "the mender's writes changed count: \(allowedWrites)")
    }
}
