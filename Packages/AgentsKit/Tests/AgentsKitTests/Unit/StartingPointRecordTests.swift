import Foundation
import Testing
@testable import AgentsKitCore

/// Where an agent started is on its record, and a record from before 035 still opens.
@Suite("An agent's starting point")
struct StartingPointRecordTests {
    private let point = StartingPoint(repository: URL(filePath: "/Users/a/Agents"),
                                      commit: "5d8fb8f0c0ffee0123456789abcdef0123456789")

    @Test func itRoundTrips() throws {
        let agent = Agent(runtimeID: "claude", cwd: URL(filePath: "/Users/a/Agents"),
                          startingPoint: point)
        let back = try JSONDecoder().decode(Agent.self, from: JSONEncoder().encode(agent))
        #expect(back.startingPoint == point)
    }

    @Test func aRecordWithoutOneStillOpens() throws {
        let agent = Agent(runtimeID: "claude", cwd: URL(filePath: "/tmp"))
        var object = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(agent)) as? [String: Any])
        object["startingPoint"] = nil
        let back = try JSONDecoder().decode(Agent.self,
                                            from: JSONSerialization.data(withJSONObject: object))
        #expect(back.startingPoint == nil)
    }

    @Test func noneIsNotWritten() throws {
        let agent = Agent(runtimeID: "claude", cwd: URL(filePath: "/tmp"))
        let object = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(agent)) as? [String: Any])
        #expect(object["startingPoint"] == nil)
    }
}
