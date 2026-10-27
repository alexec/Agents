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
        #expect(entry.host == MachineRef(rawValue: "box12345"))
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
        var entry = DaemonAPI.AuditEntry(id: "x", at: .now, action: "Changed folder detection",
                                         method: "control/setFolderDetection", actor: .init(user: "u"))
        #expect(AuditWords.place(entry) { $0.rawValue } == "on the control plane")
        #expect(AuditWords.call(entry) == "control/setFolderDetection")
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

    @Test func aShorterTimeSaysWhatItDeletes() {
        let now = Date(timeIntervalSinceReferenceDate: 782_654_400)
        func entry(_ id: String, _ days: Double) -> DaemonAPI.AuditEntry {
            .init(id: id, at: now.addingTimeInterval(-days * 86_400), action: "", method: "m", actor: .init(user: "u"))
        }
        var list = DaemonAPI.AuditList(entries: [entry("a", 1), entry("b", 40), entry("c", 200)], days: 365, more: false, admin: true)
        #expect(AuditWords.older(list, than: 30, now: now) == 2)
        #expect(AuditWords.older(list, than: 180, now: now) == 1)
        list.more = true
        #expect(AuditWords.older(list, than: 30, now: now) == nil)
        #expect(AuditWords.shorterTitle(30) == "Keep the audit for 30 days?")
        #expect(AuditWords.shorterMessage(from: 365, to: 30, older: 2)
            == "Everyone's entries older than 30 days are deleted in a day (up to 335 days of them, 2 entries now). To keep them, choose 365 days again before then.")
        #expect(AuditWords.shorterMessage(from: 2, to: 1, older: nil)
            == "Everyone's entries older than 1 day are deleted in a day (up to 1 day of them). To keep them, choose 2 days again before then.")
        #expect(AuditWords.choices(with: 90) == [30, 90, 180, 365])
        #expect(AuditWords.choices(with: 7) == [7, 30, 90, 180, 365])
    }

    /// #2087: the window and the Remote make the same CSV as the web page's auditCSV.
    @Test func jsonLinesBecomeTheWebPagesCSV() throws {
        let lines = [
            #"{"id":"1","at":0,"action":"Stopped an agent","method":"agents/stop","host":"H1","target":"A1","actor":{"user":"u","userName":"Bea, admin"}}"#,
            "not json",
            #"{"id":"2","at":60,"action":"Approved","method":"hosts/approveJoin","actor":{"user":"b","event":{"kind":"schedule","id":"w"}}}"#,
        ].joined(separator: "\n")
        let csv = AuditWords.csv(lines) { "\($0.rawValue)'s box" }.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        try #require(csv.count == 3)
        #expect(csv[0] == "at,action,method,host,hostName,target,user,userName,client,clientName,event")
        #expect(csv[1] == #"2001-01-01T00:00:00.000Z,Stopped an agent,agents/stop,H1,H1's box,A1,u,"Bea, admin",,,"#)
        #expect(csv[2].hasSuffix(",schedule w"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 9)))
        #expect(AuditWords.exportName(day, csv: true, calendar: calendar) == "audit-2026-10-20.csv")
    }
}
