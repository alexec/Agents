import AgentsKitCore
import Foundation
import UserNotifications

/// This device's banner for a need the Mac has routed here — a **local** notification,
/// which reaches the person only while the app is running. That is the LAN link's
/// limit, not this file's: a push that wakes a backgrounded phone is Slice C.
///
/// The same two jobs as the Mac's `MacNotifier` and the same idempotent rule: mine and
/// not showing → show, with sound iff alert; not mine and showing → withdraw; over and
/// showing → withdraw. It decides nothing (FR-012).
@MainActor
final class DeviceNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// Open that agent's conversation, with the question in front of the person.
    var open: @MainActor (UUID) -> Void = { _ in }
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
        let content = UNMutableNotificationContent()
        let headline = need.headline.truncating()
        content.title = headline.h2
        content.subtitle = headline.h1
        content.body = headline.h3
        content.sound = alert ? .default : nil
        content.userInfo = ["agentID": need.agentID.uuidString]
        content.threadIdentifier = need.agentID.uuidString
        showing[token] = need.id
        center.add(UNNotificationRequest(identifier: token, content: content, trigger: nil)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.showing.removeValue(forKey: token) }
        }
    }

    private func withdraw(_ token: String) {
        showing.removeValue(forKey: token)
        center.removeDeliveredNotifications(withIdentifiers: [token])
        center.removePendingNotificationRequests(withIdentifiers: [token])
    }

    /// Asked the first time a need would be shown here, where the person can see why
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
        guard let text = response.notification.request.content.userInfo["agentID"] as? String,
              let agentID = UUID(uuidString: text) else { return }
        await MainActor.run { open(agentID) }
    }
}
