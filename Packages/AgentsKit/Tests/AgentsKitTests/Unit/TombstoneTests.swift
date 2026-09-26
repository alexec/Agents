import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What is left of a retired agent (051, FR-015): the named fields, nothing else, and
/// under 2 KB.
@Suite("Tombstone")
struct TombstoneTests {
    static var fixture: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()      // Unit
            .deletingLastPathComponent()      // AgentsKitTests
            .appending(path: "Fixtures/archived-agent.json")
    }

    static func archivedAgent() throws -> Agent {
        try StoreCoding.decoder.decode(Agent.self, from: Data(contentsOf: fixture))
    }

    @Test func itKeepsExactlyTheNamedFields() throws {
        var agent = try Self.archivedAgent()
        agent.archivedAt = Date(timeIntervalSince1970: 1_800_000_000)
        agent.startedByAgent = UUID()
        let retiredAt = Date(timeIntervalSince1970: 1_802_592_000)
        let tombstone = Tombstone(from: agent, retiredAt: retiredAt, because: .age)
        let json = try JSONSerialization.jsonObject(with: StoreCoding.encoder.encode(tombstone)) as! [String: Any]
        #expect(Set(json.keys).isSubset(of: [
            "id", "title", "project", "runtimeID", "createdAt", "lastActivityAt", "archivedAt",
            "retiredAt", "endedReason", "archivedReason", "costToDate", "startedByWorkflow",
            "startedByRun", "startedByAgent", "worktreeName", "worktreeBranch", "retiredBecause",
        ]))
        #expect(tombstone.id == agent.id)
        #expect(tombstone.project == agent.projectFolder)
        #expect(tombstone.archivedAt == agent.archivedAt)
        #expect(tombstone.startedByAgent == agent.startedByAgent)
        #expect(tombstone.retiredBecause == .age)
    }

    @Test func itIsUnderTwoKilobytesAtItsLargest() throws {
        var agent = try Self.archivedAgent()
        agent.title = String(repeating: "t", count: 5_000)
        agent.costToDate = ["USD": 123.456, "EUR": 99.1, "GBP": 7, "JPY": 12_000, "CHF": 0.5]
        agent.startedByWorkflow = String(repeating: "w", count: 120)
        agent.startedByRun = UUID()
        agent.startedByAgent = UUID()
        agent.endedReason = .endTurn
        let tombstone = Tombstone(from: agent, retiredAt: Date(), because: .cap)
        #expect(tombstone.title?.count == Tombstone.titleLimit)
        #expect(try StoreCoding.encoder.encode(tombstone).count < 2_048)
    }

    @Test func itCarriesNoConversationOptionsOrCommands() throws {
        var agent = try Self.archivedAgent()
        agent.queuedPrompts = [QueuedPrompt(text: "a secret prompt")]
        let data = try StoreCoding.encoder.encode(Tombstone(from: agent, retiredAt: Date(), because: .person))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("a secret prompt"))
        #expect(!text.contains("availableCommands"))
        #expect(!text.contains(agent.availableCommands.first?.name ?? "never"))
        #expect(!text.contains("advertisedOptions"))
    }

    @Test func itRoundTrips() throws {
        let tombstone = Tombstone(from: try Self.archivedAgent(), retiredAt: Date(timeIntervalSince1970: 1_800_000_000),
                                  because: .age)
        let back = try StoreCoding.decoder.decode(Tombstone.self, from: StoreCoding.encoder.encode(tombstone))
        #expect(back == tombstone)
    }
}

/// The words, as the contract gives them (051, `contracts/daemon-api.md`, Words).
@Suite("Retirement words")
struct RetirementWordsTests {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }
    let noon = ISO8601DateFormatter().date(from: "2026-10-09T12:00:00Z")!

    @Test func rowNotes() {
        let day: TimeInterval = 86_400
        #expect(RetirementWords.rowNote(.at(noon.addingTimeInterval(3 * day)), now: noon, calendar: calendar)
                == "Retires in 3 days")
        #expect(RetirementWords.rowNote(.at(noon.addingTimeInterval(day)), now: noon, calendar: calendar)
                == "Retires tomorrow")
        #expect(RetirementWords.rowNote(.at(noon.addingTimeInterval(3_600)), now: noon, calendar: calendar)
                == "Retires today")
        #expect(RetirementWords.rowNote(.nextUnderCap, now: noon, cap: .gb2) == "Next to be retired to stay under 2 GB")
        #expect(RetirementWords.rowNote(.held(.worktreeHasWork), now: noon) == "Kept: its worktree has work in it")
        #expect(RetirementWords.rowNote(.held(.workflowRunning), now: noon) == "Kept: a workflow run is still going")
        #expect(RetirementWords.rowNote(.held(.openInWindow), now: noon) == nil)
        #expect(RetirementWords.rowNote(nil, now: noon) == nil)
    }

    @Test func theRetiredLine() {
        #expect(RetirementWords.retiredLine(12) == "12 older agents have been retired.")
        #expect(RetirementWords.retiredLine(1) == "1 older agent has been retired.")
        #expect(RetirementWords.retiredLine(0) == nil)
        #expect(RetirementWords.retiredLine(nil) == nil)
    }

    @Test func theRetiredSentence() throws {
        var agent = try TombstoneTests.archivedAgent()
        agent.title = "Title"
        let retired = ISO8601DateFormatter().date(from: "2026-10-12T09:00:00Z")!
        agent.archivedAt = retired.addingTimeInterval(-30 * 86_400)
        let tombstone = Tombstone(from: agent, retiredAt: retired, because: .age)
        #expect(RetirementWords.retiredSentence(tombstone, calendar: calendar)
                == "\u{201C}Title\u{201D} was retired on 12 October, 30 days after it was archived.")
    }

    @Test func settings() {
        #expect(RetirementWords.settingsSummary(archivedCount: 263, archivedBytes: 791_000_000,
                                                settings: RetentionSettings())
                == "263 archived agents, 791 MB. Kept 30 days, up to 2 GB.")
        #expect(RetirementWords.settingsSummary(archivedCount: 1, archivedBytes: 5_000_000,
                                                settings: RetentionSettings(keepFor: .forever, cap: .none))
                == "1 archived agent, 5 MB. Archived agents are kept forever.")
        #expect(RetirementWords.overCapSentence(OverCap(bytesOver: 120_000_000, holding: [.worktreeHasWork: 2]),
                                                cap: .gb2)
                == "Archived agents are 120 MB over 2 GB. 2 are kept because their worktrees have work in them.")
        #expect(RetirementWords.confirmSettings(count: 41, bytes: 584_000_000)
                == "This retires 41 archived agents now and frees 584 MB. Their conversations are deleted and cannot be brought back.")
        #expect(RetirementWords.confirmRetire(title: "Title", bytes: 5_400_000)
                == "Retire \u{201C}Title\u{201D}? Its conversation (5.4 MB) is deleted and cannot be brought back.")
    }
}
