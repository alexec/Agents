import AgentsKitCore
import Foundation
import UserNotifications

/// This device's banner for a need the Mac has routed here — a **local** notification
/// while the app is running and the LAN carries the decision; when it is not, a push
/// through the mailbox does the same job, loud ones opened by `RemoteNotify` and
/// silent ones handed here by `RemoteModel.receivedPush`. The push half of withdrawal
/// is **best effort** by Apple's design: a silent push is low priority, coalesced
/// one-deep, and not delivered at all to a force-quit app — which is why `sweep` on
/// coming to the front is not optional.
///
/// The same two jobs as the Mac's `MacNotifier` and the same idempotent rule: mine and
/// not showing → show, with sound iff alert; not mine and showing → withdraw; over and
/// showing → withdraw. It decides nothing (FR-012).
@MainActor
final class DeviceNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// Open that agent's conversation, with the question in front of the person.
    var open: @MainActor (UUID) -> Void = { _ in }
    /// The same, from a pushed banner that names only the need.
    var openNeed: @MainActor (String) -> Void = { _ in }
    /// The permission was asked, or refused; the presence report should say so.
    var authorisationChanged: @MainActor () -> Void = {}

    private let center = UNUserNotificationCenter.current()
    private var showing: [String: NeedID] = [:]
    private var authorised: Bool?

    override init() {
        super.init()
        center.delegate = self
    }

    func apply(_ change: DaemonAPI.AttentionNotification, me: Surface) async {
        let token = change.needID.token
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

    /// On coming to the front: anything delivered that the Mac no longer lists is stale.
    func sweep(keeping pending: DaemonAPI.AttentionPending) async {
        let live = Set(pending.needs.map(\.id.token))
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        let stale = delivered.filter { !live.contains($0) && showing[$0] != nil }
        if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        showing = showing.filter { live.contains($0.key) }
    }

    private func show(_ need: Need, token: String, alert: Bool) {
        show(need.headline, needID: need.id, alert: alert, agentID: need.agentID)
    }

    /// A headline opened from a push, or one the Mac sent in the clear over the LAN.
    func show(_ headline: Headline, needID: NeedID, alert: Bool, agentID: UUID? = nil) {
        let token = needID.token
        let content = UNMutableNotificationContent()
        let headline = headline.truncating()
        content.title = headline.h2
        content.subtitle = headline.h1
        content.body = headline.h3
        content.sound = alert ? .default : nil
        content.userInfo = ["needToken": token]
        if let agentID { content.userInfo["agentID"] = agentID.uuidString }
        content.threadIdentifier = agentID?.uuidString ?? token
        showing[token] = needID
        center.add(UNNotificationRequest(identifier: token, content: content, trigger: nil)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.showing.removeValue(forKey: token) }
        }
    }

    func withdraw(_ token: String) {
        showing.removeValue(forKey: token)
        center.removeDeliveredNotifications(withIdentifiers: [token])
        center.removePendingNotificationRequests(withIdentifiers: [token])
    }

    /// Asked when the Mac has taken this device's announce — the moment it has become
    /// a device that can be told things, which is where the "why" is plainest (FR-024).
    /// Not later: the Mac never chooses a device that has not said it can notify
    /// (FR-023), so a device that only asked when first chosen would never be asked.
    /// The answer goes back to the Mac in the next presence report.
    func requestIfUndetermined() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        authorised = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        authorisationChanged()
    }

    /// Asked the first time a need would be shown here if it somehow was not already
    /// (FR-024); the answer is reported back to the Mac as `mayNotify` (FR-023).
    private func ensureAuthorised() async -> Bool {
        if let authorised { return authorised }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: authorised = true
        case .denied: authorised = false
        default:
            authorised = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            authorisationChanged()
        }
        return authorised ?? false
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        if let text = userInfo["agentID"] as? String, let agentID = UUID(uuidString: text) {
            await MainActor.run { open(agentID) }
        } else if let token = userInfo["needToken"] as? String {
            await MainActor.run { openNeed(token) }
        }
    }
}
