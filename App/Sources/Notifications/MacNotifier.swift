import AgentsKit
import AppKit
import Foundation
import OSLog
import UserNotifications

/// The Mac's banner for a need the daemon has routed here.
///
/// It applies one idempotent rule to every `attention/changed` it hears, and nothing
/// else: *`to` is me and I am not showing it → show it, with sound iff `alert`; `to` is
/// not me and I am showing it → withdraw; the need is over and I am showing it →
/// withdraw; otherwise nothing.* It **decides nothing** — which surface should show a
/// need is the daemon's to say (FR-012), and this file being unable to say it is that
/// rule expressed as a boundary rather than a comment.
///
/// The banner's three lines come from `Need.headline` alone, built once in Core so the
/// Mac and the phone say the same words about the same agent. Swiping a banner away
/// marks nothing met: there is no "dismissed" in a need's life, the agent is still
/// blocked, and the project row still says so.
@MainActor
final class MacNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// Open that agent's conversation, with the question in front of the person.
    var open: @MainActor (UUID) -> Void = { _ in }

    private let center = UNUserNotificationCenter.current()
    private var showing: [String: NeedID] = [:]
    /// Nil until the first need would be shown here: permission is asked at a point
    /// where the person can see why, not on first launch with no context (FR-024).
    private var authorised: Bool?

    override init() {
        super.init()
        center.delegate = self
    }

    /// One `attention/changed`, applied.
    func apply(_ change: DaemonAPI.AttentionNotification, me: Surface = .mac) async {
        let token = change.needID.token
        note("notifier: change \(token) to=\(String(describing: change.to)) alert=\(change.alert) over=\(change.need == nil)")
        let isShowing = showing[token] != nil
        guard let need = change.need else {
            if isShowing { withdraw(token) }
            return
        }
        if change.to == me {
            guard !isShowing else { return }
            guard await ensureAuthorised() else { return }
            show(need, token: token, alert: change.alert)
        } else if isShowing {
            withdraw(token)
        }
    }

    /// On connecting and on coming to the front: anything still delivered that the
    /// daemon no longer lists is stale and goes — the backstop that makes a missed
    /// withdrawal survivable — and anything the daemon says is showing **here** that
    /// is not, is shown, silently. That second half is FR-010: a window that was not
    /// listening when the decision was made is put right rather than left silent.
    func sweep(keeping pending: DaemonAPI.AttentionPending, me: Surface = .mac) async {
        let live = Set(pending.needs.map(\.id.token))
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        let stale = delivered.filter { $0.hasPrefix("permission:") || $0.hasPrefix("elicitation:") || $0.hasPrefix("report:") }
            .filter { !live.contains($0) }
        if !stale.isEmpty {
            note("notifier: sweep removing stale \(stale); live \(Array(live))")
            center.removeDeliveredNotifications(withIdentifiers: stale)
        }
        showing = showing.filter { live.contains($0.key) }
        let status = await center.notificationSettings().authorizationStatus.rawValue
        Self.log.info("sweep: permission status \(status); \(delivered.count) delivered [\(delivered.joined(separator: " "), privacy: .public)]; \(pending.deliveries.filter { $0.to == me }.count) of \(pending.deliveries.count) deliveries are mine")
        note("notifier: sweep: permission status \(status); \(delivered.count) delivered \(delivered); \(pending.deliveries.filter { $0.to == me }.count) of \(pending.deliveries.count) deliveries are mine")
        for delivery in pending.deliveries where delivery.to == me {
            let token = delivery.needID.token
            guard showing[token] == nil, !delivered.contains(token),
                  let need = pending.needs.first(where: { $0.id == delivery.needID }) else { continue }
            guard await ensureAuthorised() else { return }
            show(need, token: token, alert: false)
        }
    }

    private func show(_ need: Need, token: String, alert: Bool) {
        let content = UNMutableNotificationContent()
        // The agent first, because it is what the person will recognise; the project
        // under it; what is wanted as the body. Never blank: the headline is truncated
        // rather than emptied, in Core, before it gets here.
        let headline = need.headline.truncating()
        content.title = headline.h2
        content.subtitle = headline.h1
        content.body = headline.h3
        content.sound = alert ? .default : nil
        content.userInfo = ["agentID": need.agentID.uuidString]
        content.threadIdentifier = need.agentID.uuidString
        let request = UNNotificationRequest(identifier: token, content: content, trigger: nil)
        showing[token] = need.id
        Self.log.info("showing \(token, privacy: .public), alert \(alert)")
        note("notifier: showing \(token) alert=\(alert)")
        center.add(request) { [weak self] error in
            guard let error else { return }
            Self.log.error("could not show \(token, privacy: .public): \(error, privacy: .public)")
            note("notifier: could not show \(token): \(error)")
            Task { @MainActor in self?.showing.removeValue(forKey: token) }
        }
    }

    private func withdraw(_ token: String) {
        note("notifier: withdrawing \(token)")
        showing.removeValue(forKey: token)
        center.removeDeliveredNotifications(withIdentifiers: [token])
        center.removePendingNotificationRequests(withIdentifiers: [token])
    }

    private func ensureAuthorised() async -> Bool {
        if let authorised { return authorised }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            authorised = true
        case .denied:
            authorised = false
        default:
            do {
                authorised = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                // Not remembered as a refusal: the next need asks again, and the log
                // says why this one could not.
                Self.log.error("could not ask for notification permission: \(error, privacy: .public)")
                note("notifier: could not ask for permission: \(error)")
                return false
            }
        }
        Self.log.info("notification permission: status \(settings.authorizationStatus.rawValue), authorised \(self.authorised ?? false)")
        note("notifier: permission status \(settings.authorizationStatus.rawValue), authorised \(self.authorised ?? false)")
        return authorised ?? false
    }

    private static let log = Logger(subsystem: "com.alexecollins.agents", category: "notifier")

    // MARK: UNUserNotificationCenterDelegate

    /// Shown even while the app is active: the daemon said this window is the one to
    /// show it, and it said so because the person is not looking at that conversation.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// Opening it selects that conversation. It answers nothing itself (FR-019).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        guard let text = response.notification.request.content.userInfo["agentID"] as? String,
              let agentID = UUID(uuidString: text) else { return }
        await MainActor.run {
            NSApp.activate()
            open(agentID)
        }
    }
}

/// A line on stderr, unbuffered, for a walk that runs the app from a shell. `print`
/// goes to stdout, which is block-buffered when it is a file, and says nothing until
/// the app exits.
func note(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
