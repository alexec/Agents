import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The three entries 052 adds to a conversation, and what an older reader makes of them.
@Suite("A switch in the conversation")
struct TranscriptEntryPoolTests {
    private let record = SwitchRecord(at: Date(timeIntervalSince1970: 1_790_000_000), agentID: UUID(),
                                      from: .init(runtimeID: "claude", model: "opus"),
                                      to: .init(entryID: UUID(), runtimeID: "codex", model: "gpt-5-codex"),
                                      reason: .allowanceSpent,
                                      carried: [CarriedSetting(optionID: "model", name: "Model", from: "opus",
                                                               to: "gpt-5-codex", source: .level("Strongest"))],
                                      dropped: [.alwaysAllow(count: 2)],
                                      billing: .allowance(label: "ChatGPT plan"))

    private func roundTrip(_ kind: TranscriptEntry.Kind) throws -> TranscriptEntry.Kind {
        try JSONDecoder().decode(TranscriptEntry.Kind.self, from: JSONEncoder().encode(kind))
    }

    @Test func eachRoundTrips() throws {
        #expect(try roundTrip(.poolSwitch(record)) == .poolSwitch(record))
        #expect(try roundTrip(.settingsChanged(record)) == .settingsChanged(record))
        #expect(try roundTrip(.handoff(markdown: "# Conversation so far", characters: 21))
                == .handoff(markdown: "# Conversation so far", characters: 21))
    }

    /// An older build does not know the names, and keeps each whole rather than losing
    /// the transcript; a newer shape this build cannot read is kept the same way.
    @Test func whatCannotBeReadIsKeptWhole() throws {
        let raw: JSONValue = ["poolSwitch": ["_0": ["not": "a record"]]]
        let kind = try JSONDecoder().decode(TranscriptEntry.Kind.self, from: JSONEncoder().encode(raw))
        #expect(kind == .unrecognised(raw))
    }
}
