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
        note("notifier: change \(token) to=\(String(describing: change.to)) me=\(me) alert=\(change.alert) over=\(change.need == nil)")
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

    /// On connecting and on coming to the front: anything delivered that the Mac no
    /// longer lists is stale and goes, and anything the Mac says is showing **here**
    /// that is not, is shown, silently (FR-010) — a device that was not listening when
    /// the decision was made is put right rather than left silent.
    func sweep(keeping pending: DaemonAPI.AttentionPending, me: Surface) async {
        let live = Set(pending.needs.map(\.id.token))
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        let stale = delivered.filter { !live.contains($0) }
            .filter { $0.hasPrefix("permission:") || $0.hasPrefix("elicitation:") || $0.hasPrefix("report:") }
        if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        showing = showing.filter { live.contains($0.key) }
        for delivery in pending.deliveries where delivery.to == me {
            let token = delivery.needID.token
            guard showing[token] == nil, !delivered.contains(token),
                  let need = pending.needs.first(where: { $0.id == delivery.needID }) else { continue }
            guard await ensureAuthorised() else { return }
            show(need, token: token, alert: false)
        }
    }

    private func show(_ need: Need, token: String, alert: Bool) {
        show(need.headline, needID: need.id, alert: alert, agentID: need.agentID)
    }

    /// A headline opened from a push, or one the Mac sent in the clear over the LAN.
    /// Idempotent like `apply`: a need already shown here — or shown and swiped away —
    /// is not shown again by a later silent push for the same need, which every move
    /// of it produces. A dismissed banner is a banner gone, not a need met (spec Notes).
    func show(_ headline: Headline, needID: NeedID, alert: Bool, agentID: UUID? = nil) {
        let token = needID.token
        guard showing[token] == nil else { return }
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
        note("notifier: showing \(token) alert=\(alert) \"\(headline.h3)\"")
        center.add(UNNotificationRequest(identifier: token, content: content, trigger: nil)) { [weak self] error in
            guard let error else { return }
            note("notifier: could not show \(token): \(error)")
            Task { @MainActor in self?.showing.removeValue(forKey: token) }
        }
    }

    func withdraw(_ token: String) {
        note("notifier: withdrawing \(token)")
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
        note("notifier: permission status \(settings.authorizationStatus.rawValue)")
        guard settings.authorizationStatus == .notDetermined else { return }
        authorised = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        note("notifier: asked, authorised=\(authorised ?? false)")
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

    /// On the main actor, deliberately: the async form of this callback resumes UIKit
    /// on whatever thread it finishes on, and UIKit then updates the scene snapshot for
    /// the tap — which asserts off the main thread. Marked `nonisolated` it crashed
    /// the app on every tap of a banner (2026-09-21).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let agentID = (userInfo["agentID"] as? String).flatMap(UUID.init(uuidString:))
        let token = userInfo["needToken"] as? String
        Task { @MainActor in
            if let agentID {
                open(agentID)
            } else if let token {
                openNeed(token)
            }
            completionHandler()
        }
    }
}

/// A line on stderr, unbuffered, for a walk that streams the app's console with
/// `devicectl --console`. `print` goes to stdout, which is block-buffered on a pipe.
func note(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
