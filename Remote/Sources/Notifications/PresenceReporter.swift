import AgentsKitCore
import Foundation
import SwiftUI
import UserNotifications

/// Tells the Mac where this device is in the person's hands: whether the app is in front
/// of them, and which conversation it shows — and whether it may show a notification at
/// all, so the daemon never routes to a device that cannot (FR-023).
///
/// `active` on a device means **foreground and unlocked**: `ScenePhase.active` is exactly
/// that, and a phone in a pocket with the app foregrounded is `.inactive` the moment the
/// screen locks. A report is sent on a change, never on a timer. It decides nothing.
@MainActor
final class PresenceReporter {
    typealias Report = @MainActor (UUID?, Bool, Bool?) async -> Void

    private let report: Report
    private var last: (watching: UUID?, active: Bool)?
    private var active = false
    private var watching: UUID?

    init(report: @escaping Report) {
        self.report = report
    }

    func scenePhase(_ phase: ScenePhase) {
        active = phase == .active
        send()
    }

    func watching(_ agentID: UUID?) {
        watching = agentID
        send()
    }

    /// A fresh connection is a fresh record on the Mac's side, so say it all again.
    func connected() {
        send(force: true)
    }

    private func send(force: Bool = false) {
        let now = (watching: active ? watching : nil, active: active)
        if !force, let last, last.watching == now.watching, last.active == now.active { return }
        last = now
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let mayNotify: Bool?
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: mayNotify = true
            case .denied: mayNotify = false
            default: mayNotify = nil
            }
            await report(now.watching, now.active, mayNotify)
        }
    }
}
