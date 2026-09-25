import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The parked mark on the record and on the wire, and what an older record or an older
/// phone makes of it (040).
@Suite("The parked mark, on the record and on the wire")
struct ParkingRecordTests {
    @Test(arguments: [Parking.whenTurnEnds(since: Date(timeIntervalSince1970: 1_000)),
                      .parked(at: Date(timeIntervalSince1970: 2_000))])
    func bothMarksSurviveBeingSaved(_ mark: Parking) throws {
        var agent = Agent(runtimeID: "claude", cwd: URL(filePath: "/tmp"))
        agent.parking = mark
        let read = try StoreCoding.decoder.decode(Agent.self, from: StoreCoding.encoder.encode(agent))
        #expect(read.parking == mark)
        #expect(read.unknownFields.isEmpty, "a known key, not a stray one")
    }

    @Test func aRecordFromBeforeThisFeatureIsNotParked() throws {
        let agent = Agent(runtimeID: "claude", cwd: URL(filePath: "/tmp"))
        let written = try StoreCoding.encoder.encode(agent)
        let json = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(json["parking"] == nil, "written only when there is one")
        #expect(try StoreCoding.decoder.decode(Agent.self, from: written).parking == nil)
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
        json["counts"] = counts
        let read = try JSONDecoder().decode(DaemonAPI.ProjectSummary.self,
                                            from: JSONSerialization.data(withJSONObject: json))
        #expect(read.counts == [.finished: 2, .needsAttention: 1])
        #expect(read.needsInput)
    }
}
