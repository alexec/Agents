import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A record written by the version before this one must still open.
///
/// The fixture was copied out of the real store and nothing in it was written by the
/// code under test, which is the whole of its value.
@Suite("A record from the version before")
struct LegacyRecordTests {
    private var folder: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()      // Unit
            .deletingLastPathComponent()      // AgentsKitTests
            .appending(path: "Fixtures/legacy-agent")
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = ACP.timestamp(from: text) else {
                throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
                                                       debugDescription: "not a date")
            }
            return date
        }
        return decoder
    }

    @Test func theAgentStillOpens() throws {
        let data = try Data(contentsOf: folder.appending(path: "agent.json"))
        let agent = try decoder().decode(Agent.self, from: data)
        #expect(agent.runtimeID == "claude")
        #expect(!agent.availableCommands.isEmpty)
        // None of 003's fields were in it, and their absence is not a failure.
        #expect(agent.usage == nil)
        #expect(agent.plans.isEmpty)
        #expect(agent.additionalDirectories.isEmpty)
        // Nor 014's. A record written before agents could say how it went opens as one
        // that never reported and has never been asked, which is the truth about it.
        #expect(agent.report == nil)
        #expect(agent.outcomeAsked == false)
    }

    /// The other direction, which is the one that is easy to forget: a record this
    /// build wrote, opened by one that has never heard of 014.
    @Test func aReportSurvivesADecoderThatDoesNotKnowAboutIt() throws {
        let json = #"""
        {"id":"11D9094D-5C1E-44BD-BC70-6FF7EA04375A","runtimeID":"claude",
         "cwd":"file:///tmp/x","state":"finished","endedReason":"endTurn",
         "createdAt":"2026-09-19T03:44:09.040Z","lastActivityAt":"2026-09-19T03:44:09.040Z",
         "report":{"outcome":"stuck","message":"no certificate",
                   "at":"2026-09-19T03:44:09.040Z"},"outcomeAsked":true}
        """#
        let agent = try decoder().decode(Agent.self, from: Data(json.utf8))
        #expect(agent.report?.outcome == .stuck)
        #expect(agent.report?.message == "no certificate")
        #expect(agent.outcomeAsked)
    }

    /// FR-027 on the wire. A `workReported` carrying an outcome this build does not
    /// know falls to `.unrecognised`, which keeps it whole, rather than being rounded
    /// to `done` — the unearned tick the whole feature exists to remove.
    @Test func aWorkReportedEntryWithAnUnknownOutcomeIsKeptRatherThanRounded() throws {
        let line = #"{"at":"2026-09-19T03:44:09.040Z","id":"11D9094D-5C1E-44BD-BC70-6FF7EA04375A","kind":{"workReported":{"_0":{"outcome":"succeeded","message":"all good","at":"2026-09-19T03:44:09.040Z"}}}}"#
        let entry = try decoder().decode(TranscriptEntry.self, from: Data(line.utf8))
        guard case .unrecognised = entry.kind else {
            Issue.record("an outcome we do not know must not read as one we do")
            return
        }
        // And the agent's words are still there, written back out untouched.
        let again = try JSONEncoder().encode(entry.kind)
        let value = try JSONDecoder().decode(JSONValue.self, from: again)
        #expect(value["workReported"]?["_0"]?["message"]?.stringValue == "all good")
    }

    /// The prompt origin, the same way: absent means the person's, which is what every
    /// entry written before 014 is.
    @Test func aPromptWithNoOriginIsThePersons() throws {
        let line = #"{"at":"2026-09-19T03:44:09.040Z","id":"11D9094D-5C1E-44BD-BC70-6FF7EA04375A","kind":{"userMessage":{"_0":"hello"}}}"#
        let entry = try decoder().decode(TranscriptEntry.self, from: Data(line.utf8))
        guard case .userMessage(_, _, let from) = entry.kind else {
            Issue.record("expected a user message")
            return
        }
        #expect(from == .person)
    }

    @Test func everyEntryStillReads() throws {
        let text = try String(contentsOf: folder.appending(path: "transcript.jsonl"), encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        var entries: [TranscriptEntry] = []
        for line in lines {
            entries.append(try decoder().decode(TranscriptEntry.self, from: Data(line.utf8)))
        }
        #expect(entries.count == lines.count)
        // Nothing in a record written by 001 is unreadable by 003.
        let unreadable = entries.filter { if case .unrecognised = $0.kind { return true } else { return false } }
        #expect(unreadable.isEmpty, "\(unreadable.count) entries of \(entries.count) did not read")
        #expect(entries.contains { $0.text?.contains("right sidebar") == true })
    }

    @Test func aMessageWrittenWithoutBlocksStillDraws() throws {
        let line = #"{"at":"2026-09-19T03:44:09.040Z","id":"11D9094D-5C1E-44BD-BC70-6FF7EA04375A","kind":{"userMessage":{"_0":"hello"}}}"#
        let entry = try decoder().decode(TranscriptEntry.self, from: Data(line.utf8))
        #expect(entry.text == "hello")
        // The drawing side asks for blocks, and gets the text as one.
        #expect(entry.blocks == [.text("hello")])
    }

    @Test func anEntryKindFromALaterVersionIsKeptRatherThanThrown() throws {
        let line = #"{"at":"2026-09-19T03:44:09.040Z","id":"11D9094D-5C1E-44BD-BC70-6FF7EA04375A","kind":{"somethingFromTheFuture":{"_0":42}}}"#
        let entry = try decoder().decode(TranscriptEntry.self, from: Data(line.utf8))
        guard case .unrecognised = entry.kind else {
            Issue.record("expected the kind to be kept whole")
            return
        }
        // And written back out as it came in, so passing a record through this build
        // does not delete what a later one wrote.
        let encoder = JSONEncoder()
        let again = try encoder.encode(entry.kind)
        let value = try JSONDecoder().decode(JSONValue.self, from: again)
        #expect(value["somethingFromTheFuture"]?["_0"]?.intValue == 42)
    }

    @Test func aFieldFromALaterVersionSurvivesBeingSaved() throws {
        let json = #"""
        {"id":"11D9094D-5C1E-44BD-BC70-6FF7EA04375A","runtimeID":"claude",
         "cwd":"file:///tmp/x","state":"stopped","endedReason":"endTurn",
         "createdAt":"2026-09-19T03:44:09.040Z","lastActivityAt":"2026-09-19T03:44:09.040Z",
         "somethingFromTheFuture":{"kept":true}}
        """#
        let agent = try decoder().decode(Agent.self, from: Data(json.utf8))
        #expect(agent.unknownFields["somethingFromTheFuture"]?["kept"]?.boolValue == true)
        let again = try JSONEncoder().encode(agent)
        let value = try JSONDecoder().decode(JSONValue.self, from: again)
        #expect(value["somethingFromTheFuture"]?["kept"]?.boolValue == true)
    }

    /// Both of 014's new shapes, through the store's own coder and back. The coding is
    /// hand-written in both directions, which is exactly why this is worth asserting.
    @Test func the014ShapesRoundTripUnchanged() throws {
        let report = WorkReport(outcome: .partlyDone, message: "Five of six.", at: Date())
        let kinds: [TranscriptEntry.Kind] = [
            .workReported(report),
            .userMessage("do it", from: .person),
            .userMessage("That turn ended without a report.", from: .app),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for kind in kinds {
            let again = try decoder.decode(TranscriptEntry.Kind.self,
                                           from: try encoder.encode(kind))
            #expect(again == kind)
        }
    }
}
