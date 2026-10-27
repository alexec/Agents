import AgentsKitCore
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
/// blocked, and the folder row still says so.
@MainActor
final class MacNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// Open that agent's conversation, with the question in front of the person.
    var open: @MainActor (UUID) -> Void = { _ in }
    /// A folder's page, for a question asked of the folder rather than a session (#531).
    var openFolder: @MainActor (URL) -> Void = { _ in }
    /// One of the banner's own buttons (#1170): the need's token, the answer, and the line
    /// typed for a reply.
    var answer: @MainActor (String, QuickAnswer, String?) async -> Void = { _, _, _ in }

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
        // The agent first, because it is what the person will recognise; the folder
        // under it; what is wanted as the body. Never blank: the headline is truncated
        // rather than emptied, in Core, before it gets here.
        let headline = need.headline.truncating()
        content.title = headline.h2
        content.subtitle = headline.h1
        content.body = headline.h3
        content.sound = alert ? .default : nil
        content.userInfo = ["needToken": token]
        if let agentID = need.agentID {
            content.userInfo["agentID"] = agentID.uuidString
            content.threadIdentifier = agentID.uuidString
        } else {
            // The folder's own question (#531): its token names the folder.
            content.threadIdentifier = token
        }
        showing[token] = need.id
        Self.log.info("showing \(token, privacy: .public), alert \(alert)")
        note("notifier: showing \(token) alert=\(alert) answers=\(headline.answers?.count ?? 0)")
        Task { [weak self, center] in
            // Its buttons first (#1170): a category must be known before the banner is.
            await BannerAnswers.apply(headline.answers, to: content)
            do {
                try await center.add(UNNotificationRequest(identifier: token, content: content, trigger: nil))
            } catch {
                Self.log.error("could not show \(token, privacy: .public): \(error, privacy: .public)")
                note("notifier: could not show \(token): \(error)")
                self?.showing.removeValue(forKey: token)
            }
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

    private nonisolated static let log = Logger(subsystem: "com.alexecollins.agents", category: "notifier")

    // MARK: UNUserNotificationCenterDelegate

    /// Shown even while the app is active: the daemon said this window is the one to
    /// show it, and it said so because the person is not looking at that conversation.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// Opening it selects that conversation (FR-019). One of its buttons answers the
    /// question as the card would, without bringing the window forward (#1170).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        if let chosen = BannerAnswers.chosen(in: response) {
            await Task { @MainActor in await answer(chosen.token, chosen.answer, chosen.typed) }.value
            return
        }
        let request = response.notification.request
        if let text = request.content.userInfo["agentID"] as? String, let agentID = UUID(uuidString: text) {
            await MainActor.run {
                NSApp.activate()
                open(agentID)
            }
        } else if let folder = NeedID.guardedFolder(fromToken: request.identifier) {
            await MainActor.run {
                NSApp.activate()
                openFolder(folder)
            }
        }
    }
}

/// A line on stderr, unbuffered, for a walk that runs the app from a shell. `print`
/// goes to stdout, which is block-buffered when it is a file, and says nothing until
/// the app exits.
///
/// In the unified log too (#2700): the installed window's stderr is /dev/null, and voice
/// mode's lines (#2679) were lost there. Read them with
/// `log show --predicate 'subsystem == "com.alexecollins.agents.store" AND category == "voice"'`.
/// The lines hold states, formats, counts and errors, never what the person wrote or said,
/// so they are public.
func note(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
    NoteLog.logger(for: line).log("\(line, privacy: .public)")
}

private enum NoteLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "com.alexecollins.agents.store"
    static let voice = Logger(subsystem: subsystem, category: "voice")
    static let other = Logger(subsystem: subsystem, category: "note")

    static func logger(for line: String) -> Logger {
        line.hasPrefix("voice:") || line.hasPrefix("dictation:") ? voice : other
    }
}
