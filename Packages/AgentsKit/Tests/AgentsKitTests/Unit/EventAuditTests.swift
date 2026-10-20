@testable import AgentsKitCore
import Foundation
import Testing

/// Events ▸ Audit's words (#996), and an answer as the Go control plane writes it.
struct EventAuditTests {
    @Test func anAnswerFromTheControlPlaneReads() throws {
        let line = #"""
        {"entries":[{"id":"2026-10-20/1760961600000-ab12cd34","at":782654400,"action":"Stopped an agent","method":"agents/stop",
        "host":"box12345","target":"A1","actor":{"user":"owner","userName":"Local owner",
        "client":"0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0","clientName":"MacBook Pro"}}],"days":90,"more":false,"admin":true}
        """#
        let list = try JSONDecoder().decode(DaemonAPI.AuditList.self, from: Data(line.utf8))
        let entry = try #require(list.entries.first)
        #expect(list.admin && list.days == 90 && !list.more)
        #expect(entry.host == HostID(rawValue: "box12345"))
        #expect(AuditWords.who(entry.actor) == "Local owner · MacBook Pro")
        #expect(AuditWords.place(entry) { _ in "box" } == "on box")
        #expect(AuditWords.call(entry) == "agents/stop · A1")
    }

    /// An event a person's call raised carries their actor, as agentsd writes it (#1751).
    @Test func anEventSaysWhoRaisedIt() throws {
        let line = #"""
        {"position":7,"name":"agent.started","at":782654400,"count":1,"scope":{"mac":{}},"sentence":"Fix started working.",
        "details":{},"chainDepth":0,"consequences":[],"actor":{"user":"ana","userName":"Ana","clientName":"Ana's iPhone"}}
        """#
        let event = try JSONDecoder().decode(Event.self, from: Data(line.utf8))
        #expect(event.actor.map(AuditWords.who) == "Ana · Ana's iPhone")
    }

    @Test func theControlPlanesOwnAndABotsAreSaidSo() {
        var entry = DaemonAPI.AuditEntry(id: "x", at: .now, action: "Changed project detection",
                                         method: "control/setProjectDetection", actor: .init(user: "u"))
        #expect(AuditWords.place(entry) { $0.rawValue } == "on the control plane")
        #expect(AuditWords.call(entry) == "control/setProjectDetection")
        #expect(AuditWords.who(entry.actor) == "Someone")
        entry.actor = .init(user: "b", userName: "Nightly", event: .init(kind: "pr.merged", id: "42"))
        #expect(AuditWords.who(entry.actor) == "Nightly · for pr.merged")
        #expect(AuditWords.kept(1) == "Kept for 1 day")
        #expect(AuditWords.kept(90) == "Kept for 90 days")
    }

    @Test func entriesAreCutIntoDaysNewestFirst() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let noon = Date(timeIntervalSinceReferenceDate: 782_654_400)
        func entry(_ id: String, _ hours: Double) -> DaemonAPI.AuditEntry {
            .init(id: id, at: noon.addingTimeInterval(hours * 3600), action: "", method: "m", actor: .init(user: "u"))
        }
        let days = AuditWords.days([entry("a", -30), entry("b", 1), entry("c", -1)], calendar: calendar)
        #expect(days.map { $0.entries.map(\.id) } == [["b", "c"], ["a"]])
    }
}
