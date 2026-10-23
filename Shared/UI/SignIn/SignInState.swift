import AgentsKitCore
import Foundation
import Observation

/// What a client keeps of sign-in (#995): the GitHub sign-ins waiting for this person's
/// Approve, and a count that goes up when a waiting one ends, so a card goes at once.
///
/// The window's model and the Remote's each own one, beside `PeopleState`, and feed it from
/// the control plane's own connection: `connected` when it answers, `heard` for each
/// notification, `went` when it goes.
@MainActor @Observable
final class SignInState {
    private(set) var queue = SignInRequestQueue()
    /// Requests answered from here and not decided yet: their buttons wait.
    private(set) var answering: Set<String> = []
    /// This person's organisation turned their access off (#1002, FR-029): the client shows
    /// only that, keeps its key, and goes on dialling until it is let in again.
    private(set) var suspended = false

    /// The approval cards to show now.
    func open(at now: Date = Date()) -> [DaemonAPI.SignInRequest] { queue.open(at: now) }

    /// The control plane answered: what waits for this person. One from before sign-in does
    /// not know the method: no cards.
    func connected(_ control: DaemonClient) async {
        suspended = false
        let listed = try? await control.call(DaemonAPI.Method.signInRequests, DaemonAPI.Empty(),
                                             returning: [DaemonAPI.SignInRequest].self)
        queue.replace(with: listed ?? [])
    }

    /// A notification from the control plane. True when it was one of sign-in's.
    func heard(_ method: String, _ params: JSONValue?) -> Bool {
        switch method {
        case DaemonAPI.Notification.controlSignInRequested:
            if let request = try? params?.decode(DaemonAPI.SignInRequest.self) { queue.add(request) }
        case DaemonAPI.Notification.controlCutOff:
            // The connection closes next, and the next dial is refused as suspended.
            if (try? params?.decode(DaemonAPI.ControlCutOff.self))?.why == "suspended" { suspended = true }
        case DaemonAPI.Notification.controlSignInDecided:
            if let decided = try? params?.decode(DaemonAPI.SignInDecided.self) {
                queue.remove(decided.request)
                answering.remove(decided.request)
            }
        default:
            return false
        }
        return true
    }

    /// A dial refused: suspended when the control plane said so.
    func refused(_ error: any Error) {
        if (error as? ControlAuth.Refusal)?.reason == .suspended { suspended = true }
    }

    /// A dial refused, by its reason.
    func refused(_ reason: ControlAuth.Reason?) {
        if reason == .suspended { suspended = true }
    }

    /// The control plane went: nothing can be approved until it is back.
    func went() {
        queue = SignInRequestQueue()
        answering = []
    }

    /// Approve or Deny on a card. Nil once answered; else why not, and the card stays.
    func answer(_ request: DaemonAPI.SignInRequest, approve: Bool, code: String? = nil, on control: DaemonClient?) async -> String? {
        guard let control else { return "The control plane can’t be reached, so the sign-in was not answered." }
        guard answering.insert(request.request).inserted else { return nil }
        defer { answering.remove(request.request) }
        do {
            _ = try await control.call(approve ? DaemonAPI.Method.signInApprove : DaemonAPI.Method.signInDeny,
                                       DaemonAPI.SignInDecide(request: request.request, code: approve ? code : nil))
            queue.remove(request.request)
            return nil
        } catch {
            return PeopleWords.refusal(error)
        }
    }
}
