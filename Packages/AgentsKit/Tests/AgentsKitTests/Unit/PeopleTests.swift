@testable import AgentsKitCore
import Foundation
import Testing

/// Settings ▸ People and the approval card's words (#994), and answers as the Go control
/// plane writes them.
struct PeopleTests {
    @Test func aListFromTheControlPlaneReads() throws {
        let line = #"""
        {"people":[{"id":"owner","name":"Alex","kind":"person","role":"admin","localOwner":true,"you":true,
        "signIns":[{"provider":"local"}],
        "clients":[{"id":"0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0","name":"MacBook Pro","kind":"mac"}],
        "machines":[{"id":"box12345","name":"box","state":"online","platform":"linux"}]}],"admin":true}
        """#
        let list = try JSONDecoder().decode(DaemonAPI.PeopleList.self, from: Data(line.utf8))
        let alex = try #require(list.people.first)
        #expect(list.admin)
        #expect(PeopleWords.badges(alex) == "You · Local owner · Admin")
        #expect(PeopleWords.machines(alex) == "box (online)")
        #expect(PeopleWords.clients(alex) == "MacBook Pro")
        #expect(!PeopleWords.canRemove(alex))
    }

    @Test func aRoleOrKindALaterBuildAddedReadsAsTheLeast() throws {
        let line = #"{"id":"b","name":"Nightly","kind":"robot","role":"owner","signIns":[],"clients":[],"machines":[]}"#
        let row = try JSONDecoder().decode(DaemonAPI.PersonRow.self, from: Data(line.utf8))
        #expect(row.role == .member && row.kind == .person)
    }

    @Test func removingSaysWhatGoes() {
        var sam = DaemonAPI.PersonRow(id: "sam", name: "Sam", role: .member)
        #expect(PeopleWords.canRemove(sam))
        #expect(PeopleWords.removeMessage(sam) == "Sam can no longer reach the control plane. They have no clients and no machines.")
        sam.clients = [.init(id: UUID(), name: "Sam’s iPhone", kind: .iPhone)]
        sam.machines = [.init(id: HostID(rawValue: "h1"), name: "studio", state: "offline")]
        #expect(PeopleWords.removeMessage(sam)
            == "Sam can no longer reach the control plane. These clients are forgotten: Sam’s iPhone. These machines leave the control plane: studio.")
        #expect(PeopleWords.badges(sam) == "Member")
    }

    @Test func theCardSaysWhoTheMachineIsFor() throws {
        let line = #"{"request":"r1","name":"studio","platform":"linux","code":"4F7-2KQ","expires":782654400,"for":"owner"}"#
        var request = try JSONDecoder().decode(DaemonAPI.JoinRequest.self, from: Data(line.utf8))
        #expect(request.forUser == "owner")
        #expect(PeopleWords.joinTitle(request, you: "owner") == "studio wants to join as you")
        request.forUser = "sam"
        request.forName = "Sam"
        #expect(PeopleWords.joinTitle(request, you: "owner") == "studio wants to join as Sam")
        request.forUser = ""
        #expect(PeopleWords.joinTitle(request, you: "owner") == "studio wants to join. It names no person.")
        #expect(PeopleWords.joinCode(request) == "Check that the machine shows 4F7-2KQ.")
        #expect(PeopleWords.platform("linux") == "Linux machine")
        let written = try JSONValue.encoding(request)
        #expect(written["for"]?.stringValue == "" && written["forUser"] == nil)
    }

    @Test func theQueueKeepsOneCardEachAndNoneOutOfTime() {
        let now = Date(timeIntervalSinceReferenceDate: 782_654_400)
        func request(_ id: String, _ minutes: Double) -> DaemonAPI.JoinRequest {
            .init(request: id, name: id, platform: "linux", code: "c", expires: now.addingTimeInterval(minutes * 60), forUser: "u")
        }
        var queue = JoinRequestQueue([request("a", 5), request("b", -1)])
        queue.add(request("a", 9))
        queue.add(request("c", 5))
        #expect(queue.requests.map(\.request) == ["a", "b", "c"])
        #expect(queue.open(at: now).map(\.request) == ["a", "c"])
        queue.remove("a")
        #expect(queue.open(at: now).map(\.request) == ["c"])
    }

    @Test func theInviteSaysUntilWhenAndWhatToDo() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let invited = DaemonAPI.PersonInvited(text: "code", expires: Date(timeIntervalSinceReferenceDate: 782_654_400),
                                              name: "Sam", role: .member)
        let foot = PeopleWords.inviteFoot(invited, calendar: calendar, locale: Locale(identifier: "en_US"))
        #expect(foot.hasPrefix("Works once, until Oct"))
        #expect(foot.hasSuffix("Send it to Sam; they paste it where a code is asked for."))
    }
}
