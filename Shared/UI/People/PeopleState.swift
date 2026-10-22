import AgentsKitCore
import Foundation
import Observation

/// What a client keeps of people (#994): the machines waiting for this person's approval,
/// who this client belongs to, and the one list of people and groups that every pane reads
/// (#2055), loaded once per change and not once per open pane.
///
/// The window's model and the Remote's each own one, and feed it from the control
/// plane's own connection, which only they read: `connected` when it answers, `heard` for
/// each notification, `went` when it goes.
@MainActor @Observable
final class PeopleState {
    private(set) var queue = JoinRequestQueue()
    /// Channel identities waiting for this person to link them, or for an admin to send on (#1762).
    private(set) var links = ChannelLinkRequestQueue()
    /// Goes up on `control/linksChanged`, so an open Control plane ▸ Channels loads again.
    private(set) var linksRevision = 0
    /// The people an admin can send a link request on to (#1762); empty for a member.
    private(set) var linkPeople: [DaemonAPI.PersonRow] = []
    /// Who this client belongs to, as `control/status` said. Nil from an older control plane.
    private(set) var you: DaemonAPI.ControlPerson?
    /// `control/status`'s line to run on a server so it asks to join as this person.
    private(set) var joinCommand: String?
    /// The people this client may see (#2055): every one for an admin, a member only
    /// themselves. Nil until the control plane answers.
    private(set) var list: DaemonAPI.PeopleList?
    /// Why `list` could not be loaded, in the control plane's words.
    private(set) var listProblem: String?
    /// The groups (#1761), loaded with `list`. Empty from a control plane before groups.
    private(set) var groups: [DaemonAPI.Group] = []
    /// Goes up on `control/peopleChanged` and `control/groupsChanged` (#1761), for what a
    /// pane loads beside the list.
    private(set) var revision = 0
    /// The last bot that stopped at a cap (#1761, `control/capReached`), shown to admins.
    private(set) var capReached: DaemonAPI.CapReached?
    /// Requests answered from here and not decided yet: their buttons wait.
    private(set) var answering: Set<String> = []

    /// The approval cards to show now.
    func open(at now: Date = Date()) -> [DaemonAPI.JoinRequest] { queue.open(at: now) }

    /// The control plane answered: who this client is, and what waits for them.
    func connected(_ control: DaemonClient) async {
        let status = try? await control.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self)
        you = status?.person
        joinCommand = status?.joinCommand
        // A control plane before people does not know the method: no cards.
        let listed = try? await control.call(DaemonAPI.Method.hostsJoinRequests, DaemonAPI.Empty(),
                                             returning: [DaemonAPI.JoinRequest].self)
        queue.replace(with: listed ?? [])
        await loadList(control)
        await loadLinks(control)
    }

    /// Loads the people, and the groups with them, once for every pane. False when the
    /// control plane did not answer at all, so it is worth asking again.
    @discardableResult
    func loadList(_ control: DaemonClient, groups withGroups: Bool = true) async -> Bool {
        do {
            list = try await control.call(DaemonAPI.Method.peopleList, DaemonAPI.Empty(),
                                          returning: DaemonAPI.PeopleList.self)
            listProblem = nil
        } catch {
            listProblem = PeopleWords.refusal(error)
            return error is JSONRPCError
        }
        if withGroups { await loadGroups(control) }
        return true
    }

    /// A control plane before groups has none: no bot can be made.
    private func loadGroups(_ control: DaemonClient) async {
        groups = (try? await control.call(DaemonAPI.Method.groupsList, DaemonAPI.Empty(),
                                          returning: DaemonAPI.GroupList.self))?.groups ?? []
    }

    /// The link requests this person decides, and for an admin who to send them on to.
    private func loadLinks(_ control: DaemonClient) async {
        // A control plane before links does not know the method: no cards.
        let requests = try? await control.call(DaemonAPI.Method.linksRequests, DaemonAPI.Empty(),
                                               returning: [DaemonAPI.ChannelLinkRequest].self)
        links.replace(with: requests ?? [])
        linkPeople = you?.isAdmin == true ? list?.people.filter { $0.kind == .person } ?? [] : []
    }

    /// The link cards to show now.
    func openLinks(at now: Date = Date()) -> [DaemonAPI.ChannelLinkRequest] { links.open(at: now) }

    /// A notification from the control plane. True when it was one of people's.
    func heard(_ method: String, _ params: JSONValue?, on control: DaemonClient) async -> Bool {
        switch method {
        case DaemonAPI.Notification.controlJoinRequested:
            if let request = try? params?.decode(DaemonAPI.JoinRequest.self) { queue.add(request) }
        case DaemonAPI.Notification.controlJoinDecided:
            if let decided = try? params?.decode(DaemonAPI.JoinDecided.self) {
                queue.remove(decided.request)
                answering.remove(decided.request)
            }
        case DaemonAPI.Notification.controlLinkRequested:
            if let request = try? params?.decode(DaemonAPI.ChannelLinkRequest.self) { links.add(request) }
        case DaemonAPI.Notification.controlLinkDecided:
            if let decided = try? params?.decode(DaemonAPI.ChannelLinkDecided.self) {
                links.remove(decided.request)
                answering.remove(decided.request)
            }
        case DaemonAPI.Notification.controlLinksChanged:
            linksRevision += 1
        case DaemonAPI.Notification.controlPeopleChanged:
            // A role changed or a person went: who this is, what they may approve, and the list.
            await connected(control)
            revision += 1
        case DaemonAPI.Notification.controlGroupsChanged:
            await loadGroups(control)
            revision += 1
        case DaemonAPI.Notification.controlCapReached:
            capReached = try? params?.decode(DaemonAPI.CapReached.self)
            // Only the bot's spend today changed.
            await loadList(control, groups: false)
        default:
            return false
        }
        return true
    }

    /// The control plane went: nothing can be approved until it is back.
    func went() {
        queue = JoinRequestQueue()
        links = ChannelLinkRequestQueue()
        answering = []
    }

    /// Approve or Deny on a card. Nil once answered; else why not, in the control plane's
    /// words, and the card stays.
    func answer(_ request: DaemonAPI.JoinRequest, approve: Bool, on control: DaemonClient?) async -> String? {
        guard let control else { return "The control plane can’t be reached, so the machine was not answered." }
        guard answering.insert(request.request).inserted else { return nil }
        defer { answering.remove(request.request) }
        do {
            let decide = DaemonAPI.JoinRequestDecide(request: request.request)
            if approve {
                _ = try await control.call(DaemonAPI.Method.hostsApproveJoin, decide, returning: DaemonAPI.JoinApproved.self)
            } else {
                _ = try await control.call(DaemonAPI.Method.hostsDenyJoin, decide)
            }
            queue.remove(request.request)
            return nil
        } catch {
            return PeopleWords.refusal(error)
        }
    }

    /// Approve, Deny or Send on a link card (#1762). `to` is the person an admin sends a
    /// request that names nobody on to. Nil once answered; else why not, and the card stays.
    func answerLink(_ request: DaemonAPI.ChannelLinkRequest, approve: Bool, to person: String? = nil,
                    on control: DaemonClient?) async -> String? {
        guard let control else { return "The control plane can’t be reached, so the link was not answered." }
        guard answering.insert(request.request).inserted else { return nil }
        defer { answering.remove(request.request) }
        do {
            let decide = DaemonAPI.ChannelLinkDecide(request: request.request, forUser: person)
            _ = try await control.call(approve ? DaemonAPI.Method.linksApprove : DaemonAPI.Method.linksDeny, decide)
            links.remove(request.request)
            return nil
        } catch {
            return PeopleWords.refusal(error)
        }
    }
}
