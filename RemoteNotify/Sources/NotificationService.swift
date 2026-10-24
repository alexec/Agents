import AgentsKitCore
import UserNotifications
import WidgetKit

/// The banner's words are assembled **on the device**, which is what a notification
/// service extension is for (021 FR-022).
///
/// A loud push carries the sealed headline and nothing legible: a mailbox item from a Mac
/// host's relay, or the control plane's own push when no Mac relays (#1460). This opens the envelope
/// with the device's own key — shared with the app through the keychain group — and
/// puts the folder, the agent and what is wanted into the notification. If the
/// envelope cannot be opened the system shows what the push already had: a title that
/// says only that an agent needs you, which the quickstart names as the failure to
/// watch for, so it is never silently the norm.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        self.content = content
        let userInfo = request.content.userInfo
        let key = { try? DeviceKey.load(accessGroup: DeviceKey.sharedAccessGroup) }
        // The mailbox's, from a Mac host's relay; or the control plane's own (#1460), sealed
        // whole, when no Mac relays.
        guard let pushed = CloudKitMailbox.pushed(from: userInfo)
                ?? (ControlPush.isControlPush(userInfo) ? ControlPush.pushed(from: userInfo, key: key()) : nil) else {
            contentHandler(content)
            return
        }
        let headline = pushed.headline ?? pushed.envelope.flatMap { envelope in
            key().flatMap { try? Envelope.open(envelope, with: $0) }
        }
        // A loud push never wakes the app, so the widget hears of it here (#1046), with the
        // Mac's whole count where the push carries it, which the badge shows too (#1163).
        let written = AttentionSnapshotStore.apply(AttentionPush(need: pushed.needID, headline: headline,
                                                                 withdrawn: pushed.withdraws,
                                                                 count: pushed.count))
        if written != nil {
            WidgetCenter.shared.reloadTimelines(ofKind: AttentionSnapshot.widgetKind)
        }
        if pushed.count != nil, let total = (written ?? AttentionSnapshotStore.read())?.total {
            content.badge = NSNumber(value: total)
        }
        guard let headline else {
            contentHandler(content)
            return
        }
        content.title = headline.h2
        content.subtitle = headline.h1
        content.body = headline.h3
        content.threadIdentifier = pushed.token
        content.userInfo["needToken"] = pushed.token
        // Its buttons (#1170), made here from the opened envelope: what they say is as
        // sealed as the rest. The app answers a press, woken in the background.
        guard let answers = headline.answers, !answers.isEmpty,
              let value = QuickAnswer.userInfoValue(answers) else {
            contentHandler(content)
            return
        }
        let delivery = Delivery(content: content, handler: contentHandler)
        Task {
            delivery.content.categoryIdentifier = await BannerAnswers.category(for: answers)
            delivery.content.userInfo[QuickAnswer.userInfoKey] = value
            delivery.handler(delivery.content)
        }
    }

    /// The banner and its handler, handed to the task that registers its buttons, and
    /// touched by nothing else until the handler has it.
    private struct Delivery: @unchecked Sendable {
        let content: UNMutableNotificationContent
        let handler: (UNNotificationContent) -> Void
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler, let content { handler(content) }
    }
}
