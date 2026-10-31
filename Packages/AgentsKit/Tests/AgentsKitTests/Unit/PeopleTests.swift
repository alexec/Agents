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
        sam.machines = [.init(id: MachineRef(rawValue: "h1"), name: "studio", state: "offline")]
        #expect(PeopleWords.removeMessage(sam)
            == "Sam can no longer reach the control plane. These clients are forgotten: Sam’s iPhone. These machines leave the control plane: studio.")
        #expect(PeopleWords.badges(sam) == "Member")
    }

    /// Remove's preview (#1763): started machines are deleted, with the work on each that is
    /// not pushed, and the others leave. It reads as the control plane writes it.
    @Test func removingSaysWhatWorkIsNotPushed() throws {
        var sam = DaemonAPI.PersonRow(id: "sam", name: "Sam", role: .member)
        sam.machines = [.init(id: MachineRef(rawValue: "h1"), name: "studio", state: "online")]
        let line = #"{"startedMachines":[{"host":"w1","name":"sam-ws","state":"online","unpushed":["#
            + #"{"folder":"file:///p","worktree":"file:///p-fix","branch":"agents/fix","ahead":2,"uncommitted":3},"#
            + #"{"folder":"file:///p","worktree":"file:///p-new","unmerged":1}]},"#
            + #"{"host":"w2","name":"sam-old","state":"offline","unpushed":[],"unknown":"sam-old is not online, so it could not be asked."}],"#
            + #""registeredMachines":[{"id":"h1","name":"studio","state":"online"}]}"#
        let preview = try JSONDecoder().decode(DaemonAPI.PersonRemovePreview.self, from: Data(line.utf8))
        #expect(PeopleWords.removeMessage(sam, preview: preview)
            == "Sam can no longer reach the control plane. These machines are stopped and deleted: sam-ws, sam-old. "
            + "On sam-ws, this work is not pushed and is lost: agents/fix (2 commits not pushed, changes not committed); "
            + "p-new (1 commit never pushed). sam-old is not online, so it could not be asked. "
            + "These machines leave the control plane: studio.")
        #expect(PeopleWords.asking(sam) == "Asking Sam’s machines what work on them is not pushed…")
        // A check that failed says what is at stake, and Remove stays off (#2193).
        #expect(PeopleWords.checkFailed(sam, why: "The control plane can’t be reached.")
            == "Could not check what Sam’s machines would lose. The control plane can’t be reached. Removing Sam stops and "
            + "deletes the machines Sam started, with any work on them not pushed, so Remove stays off until the check works.")
        // Remove…'s sheet: a line each, a machine to a line (#2077).
        let lines = PeopleWords.removeLines(sam, preview: preview)
        try #require(lines.count == 5)
        #expect(lines[3] == "sam-old is not online, so it could not be asked.")
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

/// The link card's and Control plane ▸ Channels' words (#1762).
@Suite("Channel link words")
struct ChannelLinkWordsTests {
    private let expires = Date(timeIntervalSinceReferenceDate: 812_345_678)

    @Test func askNamesTheIdentity() {
        let slack = DaemonAPI.ChannelLinkRequest(request: "r", channel: "slack", identity: "T1/U42", name: "@sam",
                                                 email: "sam@example.com", forUser: "sam", expires: expires)
        #expect(ChannelLinkWords.ask(slack) == "Link Slack user @sam to you?")
        #expect(ChannelLinkWords.detail(slack) == "T1/U42 · sam@example.com")
        let email = DaemonAPI.ChannelLinkRequest(request: "r", channel: "email", identity: "sam@example.com",
                                                 email: "sam@example.com", forUser: "sam", expires: expires)
        #expect(ChannelLinkWords.ask(email) == "Link the email address sam@example.com to you?")
        #expect(ChannelLinkWords.detail(email) == nil)
        let nobody = DaemonAPI.ChannelLinkRequest(request: "r", channel: "discord", identity: "1234", expires: expires)
        #expect(ChannelLinkWords.ask(nobody) == "Discord user 1234 is not linked to anyone.")
        #expect(ChannelLinkWords.explanation(nobody).hasPrefix("Send asks"))
    }

    @Test func aLinkSaysWhoseItIs() {
        let link = DaemonAPI.ChannelLink(channel: "slack", identity: "T1/U42", name: "@sam", user: "sam", userName: "Sam",
                                         approvedBy: "sam", approvedAt: expires)
        #expect(ChannelLinkWords.linkTitle(link) == "Slack user @sam")
        #expect(ChannelLinkWords.linkDetail(link, you: "sam") == "T1/U42 · linked to you")
        #expect(ChannelLinkWords.linkDetail(link, you: "alex") == "T1/U42 · linked to Sam")
        #expect(ChannelLinkWords.removeTitle(link) == "Unlink Slack user @sam?")
    }

    @Test func aQueueKeepsOneCardEach() {
        var queue = ChannelLinkRequestQueue()
        let request = DaemonAPI.ChannelLinkRequest(request: "r", channel: "slack", identity: "U1", expires: .distantFuture)
        queue.add(request)
        queue.add(request)
        #expect(queue.open().count == 1)
        queue.add(DaemonAPI.ChannelLinkRequest(request: "old", channel: "slack", identity: "U2", expires: .distantPast))
        #expect(queue.open().count == 1)
        queue.remove("r")
        #expect(queue.open().isEmpty)
    }

    /// The org provider lines under a person (#1002, FR-028).
    @Test func orgLinesSayWhoManagesAPerson() throws {
        let json = #"{"id":"u1","name":"Sam","kind":"person","role":"admin","signIns":[],"clients":[],"machines":[],"#
            + #""scim":{"provider":"acme-okta","userName":"sam@acme.com","active":false},"provisioned":true,"#
            + #""suspended":{"by":"scim","provider":"acme-okta","at":"2026-10-22T09:00:00Z"},"roleFrom":["g1"]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sam = try decoder.decode(DaemonAPI.PersonRow.self, from: Data(json.utf8))
        let names = ["acme-okta": "Acme Okta"]
        #expect(PeopleWords.orgLines(sam) { names[$0] ?? $0 }
            == ["Managed by Acme Okta", "Waiting for first sign-in", "Suspended by Acme Okta"])
        #expect(sam.roleSetBy == "acme-okta")
        #expect(PeopleWords.setBy("Acme Okta") == "Set by Acme Okta")
        let lee = DaemonAPI.PersonRow(id: "u2", name: "Lee", role: .member)
        #expect(PeopleWords.orgLines(lee) { $0 }.isEmpty && lee.roleSetBy == nil)
    }

    @Test func editInConsoleOpensConsolePeople() throws {
        let json = #"{"name":"Team","version":"1","machineID":"m","publicWeb":"https://control.example.com/"}"#
        let status = try JSONDecoder().decode(DaemonAPI.ControlStatus.self, from: Data(json.utf8))
        #expect(PeopleWords.consoleURL(status)?.absoluteString == "https://control.example.com/#/console/people")
        // A SCIM group's line on the Mac and the Remote (#1002, FR-031).
        let scim = DaemonAPI.Group(id: "g", name: "Admins", source: .init(scim: "acme", displayName: "Admins"), role: "admin")
        #expect(GroupWords.orgLine(scim, provider: "Acme Okta") == "From Acme Okta · Gives the admin role")
        #expect(GroupWords.orgLine(DaemonAPI.Group(id: "h", name: "Eng", source: .init(scim: "acme", displayName: "Eng")),
                                   provider: "Acme Okta") == "From Acme Okta")
        // The providers' Edit in Console opens Console ▸ Sign-In (#1002, D17).
        #expect(PeopleWords.signInConsoleURL(status)?.absoluteString == "https://control.example.com/#/console/signIn")
    }
}
