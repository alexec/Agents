import Foundation
import Testing

/// SC-001 and SC-007 of 019: the number of places that decide an agent's group is one.
///
/// A source scan, for the reason `LifecycleWriterTests` gives for its own: a claim about
/// where code *may* do something cannot be checked from inside the program, because the
/// line that breaks it does not exist yet. Two functions computing the group is how 019
/// happened — one could see whether an agent had asked to be looked at and one could
/// not — and one function with a defaulted argument is how it would happen quietly. So
/// the initialiser has no defaults, `Agent.group(wantsEyes:)` is the one way to reach
/// it, and this holds that nothing else calls the initialiser directly (FR-001, FR-021).
///
/// The matcher is proved to bite against a sample below. A scan that matches nothing is
/// a green test protecting nothing.
@Suite("One grouping")
struct OneGroupingTests {
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

    /// Whether this line decides a group by calling the initialiser itself.
    static func decidesAGroup(_ line: String) -> Bool {
        code(line).contains("AgentGroup(for:")
    }

    /// The one file that may: the rule's own, where `Agent.group(wantsEyes:)` lives.
    private static let theOnePlace = "Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentGroup.swift"

    @Test func theScanCatchesADecisionAndNotAMention() {
        #expect(Self.decidesAGroup("        AgentGroup(for: state, wantsEyes: wantsEyes, report: report, outcomeAsked: outcomeAsked)"))
        #expect(Self.decidesAGroup("let g = AgentGroup(for: .running, wantsEyes: false, report: nil, outcomeAsked: false)"))
        #expect(!Self.decidesAGroup("    /// Grouped by `AgentGroup(for:)`, so no client can put an agent under a heading"))
        #expect(!Self.decidesAGroup("        agent.group(wantsEyes: filesToShow[agent.id] != nil)"))
        #expect(!Self.decidesAGroup("        counts[agent.group(wantsEyes: false), default: 0] += 1"))
    }

    @Test func anAgentsGroupIsDecidedInExactlyOnePlace() throws {
        var deciders: [String] = []
        var scanned = 0
        for directory in ["Packages/AgentsKit/Sources", "App/Sources", "Remote/Sources"] {
            for source in try Self.sources(under: directory) {
                scanned += 1
                for (index, line) in source.lines.enumerated() where Self.decidesAGroup(line) {
                    deciders.append("\(source.path):\(index + 1)")
                }
            }
        }
        #expect(scanned > 60, "too few sources were read; the repository root is wrong")
        #expect(deciders.count == 1, """
            An agent's group is decided in \(deciders.count) places. It must be decided in \
            exactly one — `Agent.group(wantsEyes:)` in AgentGroup.swift — and every other \
            caller must go through it with the facts spelled out, because two places is \
            how the daemon's counts and the window's list came to disagree (019).
            \(deciders.joined(separator: "\n"))
            """)
        #expect(deciders.first?.hasPrefix(Self.theOnePlace) == true, "the one place moved: \(deciders.first ?? "none")")
    }
}
