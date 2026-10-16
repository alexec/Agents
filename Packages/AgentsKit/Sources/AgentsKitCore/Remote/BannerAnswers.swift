#if canImport(UserNotifications)
import Foundation
import UserNotifications

/// A banner's buttons in the notification centre (#1170), the same on the Mac, the
/// phone's local banner and the push the phone opens in `RemoteNotify`.
///
/// A category is a set of buttons, and the centre keeps one list of them for the app, so
/// each new set is added to the list rather than put in its place. One at a time: two
/// banners shown together must not each write the list without the other's.
public actor BannerAnswers {
    public static let shared = BannerAnswers()

    /// The most categories kept. Past it, only those of banners still showing stay.
    static let most = 32

    /// Give the banner its buttons: the category for its answers, registered first, and
    /// the answers in its `userInfo` for the tap to read. Nothing for a banner with none.
    public nonisolated(nonsending) static func apply(_ answers: [QuickAnswer]?,
                                                     to content: UNMutableNotificationContent) async {
        guard let answers, !answers.isEmpty, let value = QuickAnswer.userInfoValue(answers) else { return }
        content.categoryIdentifier = await category(for: answers)
        content.userInfo[QuickAnswer.userInfoKey] = value
    }

    /// The category for these answers, added to the centre's list if it is new.
    public static func category(for answers: [QuickAnswer]) async -> String {
        await shared.register(answers)
    }

    func register(_ answers: [QuickAnswer]) async -> String {
        let id = QuickAnswer.categoryID(for: answers)
        let center = UNUserNotificationCenter.current()
        var categories = await center.notificationCategories()
        guard !categories.contains(where: { $0.identifier == id }) else { return id }
        if categories.count >= Self.most {
            let showing = Set(await center.deliveredNotifications().map(\.request.content.categoryIdentifier))
            categories = categories.filter { showing.contains($0.identifier) }
        }
        categories.insert(Self.category(id, answers))
        center.setNotificationCategories(categories)
        return id
    }

    /// The buttons. Every one asks for the device to be unlocked first: a phone in
    /// another person's hand must not allow a command (Alex can overrule). None opens the
    /// app; the answer goes from the background.
    static func category(_ id: String, _ answers: [QuickAnswer]) -> UNNotificationCategory {
        let actions = answers.enumerated().map { index, answer -> UNNotificationAction in
            var options: UNNotificationActionOptions = [.authenticationRequired]
            if answer.isDestructive { options.insert(.destructive) }
            let identifier = QuickAnswer.actionID(at: index)
            switch answer.kind {
            case .choice:
                return UNNotificationAction(identifier: identifier, title: answer.title, options: options)
            case .reply:
                return UNTextInputNotificationAction(identifier: identifier, title: answer.title, options: options,
                                                     textInputButtonTitle: "Send", textInputPlaceholder: "Answer")
            }
        }
        return UNNotificationCategory(identifier: id, actions: actions, intentIdentifiers: [], options: [])
    }

    /// What a press of one of a banner's buttons answers: the need's token, the answer,
    /// and the line typed for a reply. Nil for a tap on the banner itself, or a swipe.
    public nonisolated static func chosen(actionIdentifier: String, userInfo: [AnyHashable: Any],
                                          requestIdentifier: String,
                                          typed: String?) -> (token: String, answer: QuickAnswer, typed: String?)? {
        guard let index = QuickAnswer.index(ofAction: actionIdentifier),
              let answers = QuickAnswer.answers(inUserInfo: userInfo), answers.indices.contains(index)
        else { return nil }
        let token = (userInfo["needToken"] as? String) ?? requestIdentifier
        return (token, answers[index], typed)
    }

    /// The same, read off the centre's response.
    public nonisolated static func chosen(in response: UNNotificationResponse)
        -> (token: String, answer: QuickAnswer, typed: String?)? {
        chosen(actionIdentifier: response.actionIdentifier,
               userInfo: response.notification.request.content.userInfo,
               requestIdentifier: response.notification.request.identifier,
               typed: (response as? UNTextInputNotificationResponse)?.userText)
    }
}
#endif
