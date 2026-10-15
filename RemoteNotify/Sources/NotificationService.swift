import AgentsKitCore
import UserNotifications
import WidgetKit

/// The banner's words are assembled **on the device**, which is what a notification
/// service extension is for (021 FR-022).
///
/// A loud push carries the sealed headline and nothing legible. This opens the envelope
/// with the device's own key — shared with the app through the keychain group — and
/// puts the project, the agent and what is wanted into the notification. If the
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
        guard let pushed = CloudKitMailbox.pushed(from: request.content.userInfo) else {
            contentHandler(content)
            return
        }
        let headline = pushed.envelope.flatMap { envelope in
            (try? DeviceKey.load(accessGroup: DeviceKey.sharedAccessGroup)).flatMap { try? Envelope.open(envelope, with: $0) }
        }
        // A loud push never wakes the app, so the widget hears of it here (#1046).
        if AttentionSnapshotStore.apply(AttentionPush(need: pushed.needID, headline: headline,
                                                      withdrawn: pushed.withdrawn || pushed.envelope == nil)) {
            WidgetCenter.shared.reloadTimelines(ofKind: AttentionSnapshot.widgetKind)
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
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler, let content { handler(content) }
    }
}
