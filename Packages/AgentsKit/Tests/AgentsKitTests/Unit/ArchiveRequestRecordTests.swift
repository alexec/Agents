import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The Asks to archive mark on the record and on the wire, and what a record from the
/// days of parking makes of it (#584).
@Suite("The request to archive, on the record and on the wire")
struct ArchiveRequestRecordTests {
    @Test(arguments: [ArchiveRequest.whenTurnEnds(since: Date(timeIntervalSince1970: 1_000)),
                      .requested(at: Date(timeIntervalSince1970: 2_000))])
    func bothMarksSurviveBeingSaved(_ mark: ArchiveRequest) throws {
        var agent = Agent(runtimeID: "claude", cwd: URL(filePath: "/tmp"))
        agent.archiveRequest = mark
        let read = try StoreCoding.decoder.decode(Agent.self, from: StoreCoding.encoder.encode(agent))
        #expect(read.archiveRequest == mark)
        #expect(read.unknownFields.isEmpty, "a known key, not a stray one")
    }

    @Test func aRecordWithNoRequestAsksForNothing() throws {
        let agent = Agent(runtimeID: "claude", cwd: URL(filePath: "/tmp"))
        let written = try StoreCoding.encoder.encode(agent)
        let json = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(json["archiveRequest"] == nil, "written only when there is one")
        #expect(try StoreCoding.decoder.decode(Agent.self, from: written).archiveRequest == nil)
    }

    /// Parked before #584: back in the group its ending puts it in, read, and asking for
    /// nothing. The old key is read and dropped, not carried on as an unknown field.
    @Test func aParkedRecordComesBackReadWhereItsEndingSays() throws {
        var agent = Agent(runtimeID: "claude", cwd: URL(filePath: "/tmp"), state: .finished, endedReason: .endTurn,
                          report: WorkReport(outcome: .done, message: "Shipped", at: Date()))
        agent.isUnread = true
        var json = try #require(try JSONSerialization.jsonObject(with: StoreCoding.encoder.encode(agent)) as? [String: Any])
        json["parking"] = ["parked": ["at": "2026-10-01T10:00:00Z"]]
        let read = try StoreCoding.decoder.decode(Agent.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(read.archiveRequest == nil)
        #expect(read.isUnread == false)
        #expect(read.group(wantsEyes: false) == .finished)
        #expect(read.unknownFields.isEmpty)
        let again = try #require(try JSONSerialization.jsonObject(with: StoreCoding.encoder.encode(read)) as? [String: Any])
        #expect(again["parking"] == nil, "and is not written back")
    }

    /// `park`, as an agent asked before #584, is the request that replaced it.
    @Test func anAskToParkReadsAsARequestToArchive() throws {
        var json = try #require(try JSONSerialization.jsonObject(
            with: StoreCoding.encoder.encode(Agent(runtimeID: "claude", cwd: URL(filePath: "/tmp")))) as? [String: Any])
        json["afterTurn"] = "park"
        let read = try StoreCoding.decoder.decode(Agent.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(read.afterTurn == .requestArchive)
        #expect(AfterTurn(wire: "park") == .requestArchive)
    }

    @Test(arguments: [AfterTurn.requestArchive, .archive])
    func anAskToBePutAwaySurvivesBeingSaved(_ after: AfterTurn) throws {
        var agent = Agent(runtimeID: "claude", cwd: URL(filePath: "/tmp"))
        agent.afterTurn = after
        let read = try StoreCoding.decoder.decode(Agent.self, from: StoreCoding.encoder.encode(agent))
        #expect(read.afterTurn == after)
        #expect(read.unknownFields.isEmpty, "a known key, not a stray one")
    }

    @Test func aRecordWithNoAskOrOneFromANewerBuildAskedForNothing() throws {
        let agent = Agent(runtimeID: "claude", cwd: URL(filePath: "/tmp"))
        let written = try StoreCoding.encoder.encode(agent)
        var json = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(json["afterTurn"] == nil, "written only when there is one")
        #expect(try StoreCoding.decoder.decode(Agent.self, from: written).afterTurn == nil)

        json["afterTurn"] = "somethingNewer"
        let newer = try StoreCoding.decoder.decode(Agent.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(newer.afterTurn == nil)
    }

    /// A group this build has never heard of is dropped, not fatal — a plain
    /// `[AgentGroup: Int]` decode throws, and took every project with it (R7).
    @Test func projectCountsWithAGroupFromANewerBuildStillOpen() throws {
        let summary = DaemonAPI.ProjectSummary(
            project: Project(folder: URL(filePath: "/tmp/api"), addedAt: Date()),
            name: "api", exists: true, lastActivityAt: Date(),
            counts: [.finished: 2, .needsAttention: 1])
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(summary)) as? [String: Any])
        var counts = try #require(json["counts"] as? [String: Any])
        counts["somethingNewer"] = 4
        // And one that went: an older Mac's Parked (#584).
        counts["parked"] = 3
        json["counts"] = counts
        let read = try JSONDecoder().decode(DaemonAPI.ProjectSummary.self,
                                            from: JSONSerialization.data(withJSONObject: json))
        #expect(read.counts == [.finished: 2, .needsAttention: 1])
        #expect(read.needsInput)
    }
}
