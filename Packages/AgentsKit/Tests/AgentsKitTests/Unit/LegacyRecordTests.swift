import Foundation
import Testing
@testable import AgentsKit

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
}
