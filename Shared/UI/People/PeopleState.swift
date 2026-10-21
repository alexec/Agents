import AgentsKitCore
import Foundation
import Observation

/// What a client keeps of people (#994): the machines waiting for this person's approval,
/// who this client belongs to, and a count that goes up each time people change, so an
/// open Settings ▸ People loads again.
///
/// The window's model and the Remote's each own one, and feed it from the control
/// plane's own connection, which only they read: `connected` when it answers, `heard` for
/// each notification, `went` when it goes.
@MainActor @Observable
final class PeopleState {
    private(set) var queue = JoinRequestQueue()
    /// Who this client belongs to, as `control/status` said. Nil from an older control plane.
    private(set) var you: DaemonAPI.ControlPerson?
    /// Goes up on `control/peopleChanged` and `control/groupsChanged` (#1761).
    private(set) var revision = 0
    /// Requests answered from here and not decided yet: their buttons wait.
    private(set) var answering: Set<String> = []

    /// The approval cards to show now.
    func open(at now: Date = Date()) -> [DaemonAPI.JoinRequest] { queue.open(at: now) }

    /// The control plane answered: who this client is, and what waits for them.
    func connected(_ control: DaemonClient) async {
        you = (try? await control.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self))?.person
        // A control plane before people does not know the method: no cards.
        let listed = try? await control.call(DaemonAPI.Method.hostsJoinRequests, DaemonAPI.Empty(),
                                             returning: [DaemonAPI.JoinRequest].self)
        queue.replace(with: listed ?? [])
    }

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
        case DaemonAPI.Notification.controlPeopleChanged:
            revision += 1
            // A role changed or a person went: who this is, and what they may approve.
            await connected(control)
        case DaemonAPI.Notification.controlGroupsChanged:
            revision += 1
        default:
            return false
        }
        return true
    }

    /// The control plane went: nothing can be approved until it is back.
    func went() {
        queue = JoinRequestQueue()
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
}
