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
    /// Watching, active, may notify, the chat the main scene has open whether in front or
    /// not (#203), and the sessions open in scenes of their own (#888).
    typealias Report = @MainActor (UUID?, Bool, Bool?, UUID?, Set<UUID>) async -> Void

    private let report: Report
    private var last: (watching: UUID?, active: Bool, showing: UUID?, popped: Set<UUID>)?
    private var active = false
    /// The main scene's chat.
    private var watching: UUID?
    /// The sessions in scenes of their own (#888), and the one of them in the key window,
    /// if one is: that one is what the person is watching while it is.
    private var popped: Set<UUID> = []
    private var poppedInFront: UUID?
    private var inFront: UUID? { poppedInFront ?? watching }
    private var tail: Task<Void, Never>?

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

    /// The sessions open in scenes of their own, and which of them is the key window (#888).
    func popped(_ ids: Set<UUID>, inFront: UUID?) {
        popped = ids
        poppedInFront = inFront.flatMap { ids.contains($0) ? $0 : nil }
        send()
    }

    /// A fresh connection is a fresh record on the Mac's side, so say it all again.
    func connected() {
        send(force: true)
    }

    private func send(force: Bool = false) {
        let now = (watching: active ? inFront : nil, active: active, showing: watching, popped: popped)
        if !force, let last, last.watching == now.watching, last.active == now.active,
           last.showing == now.showing, last.popped == now.popped { return }
        last = now
        let previous = tail
        tail = Task {
            await previous?.value
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let mayNotify: Bool?
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: mayNotify = true
            case .denied: mayNotify = false
            default: mayNotify = nil
            }
            await report(now.watching, now.active, mayNotify, now.showing, now.popped)
        }
    }
}
