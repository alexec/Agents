import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What the app's own tools add to every request an agent makes (#465).
///
/// A tool's schema is sent with every model call, not once a conversation, and a cached
/// one is still paid for each time it is read. So the bytes are measured here, a tool at
/// a time, and the whole is held under a ceiling: growing it is a choice to make on
/// purpose, by raising the ceiling, rather than something that happens one description
/// at a time. The figures are written up in docs/explanation/token-cost-of-tools.md.
@Suite("What the app's tools cost", .timeLimit(.minutes(1)))
struct ToolCostTests {
    /// Bytes as a runtime receives them: compact JSON.
    private func bytes(_ value: JSONValue) throws -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value).count
    }

    /// The tools a session is listed, as `tools/list` answers.
    private func listed(managesAgents: Bool) -> [JSONValue] {
        AppService.tools(managesAgents: managesAgents)
            + AppViewCatalog.tools(testView: false).filter(\.forModel).map(\.definition)
    }

    /// The ceiling, in bytes, on what a lead's session is listed. About four bytes a
    /// token for this English and JSON, so 40 KB is some 10,000 tokens: about a tenth
    /// over what it measured on 2026-10-08.
    static let leadCeiling = 40_000

    @Test func everyToolIsMeasuredAndTheWholeIsUnderItsCeiling() throws {
        let lead = listed(managesAgents: true)
        var rows: [(String, Int)] = []
        for tool in lead {
            rows.append((tool["name"]?.stringValue ?? "?", try bytes(tool)))
        }
        let total = rows.reduce(0) { $0 + $1.1 }
        let helper = try listed(managesAgents: false).reduce(0) { $0 + (try bytes($1)) }
        let grok = GrokToolPreface.rules(managesAgents: true).utf8.count
        let briefing = Briefing.text(for: ToolPolicyCatalog.policy(for: "claude")).utf8.count
        // The table the doc is written from: `swift test --filter ToolCostTests`.
        for (name, size) in rows.sorted(by: { $0.1 > $1.1 }) {
            print("tool-cost \(name) \(size) bytes ~\(size / 4) tokens")
        }
        print("tool-cost total lead \(total) bytes ~\(total / 4) tokens, \(rows.count) tools")
        print("tool-cost total helper \(helper) bytes ~\(helper / 4) tokens")
        print("tool-cost grok rules \(grok) bytes ~\(grok / 4) tokens")
        print("tool-cost claude briefing \(briefing) bytes ~\(briefing / 4) tokens")
        #expect(total <= Self.leadCeiling, "the app's tools grew to \(total) bytes")
        #expect(helper < total)
    }
}
