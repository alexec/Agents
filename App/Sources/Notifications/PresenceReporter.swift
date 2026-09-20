import AgentsKit
import AppKit
import Foundation

/// Tells the daemon where the person is, as far as this window can know: whether it is
/// in front of them, and which conversation it is showing.
///
/// A report is sent on a **change**, never on a timer — a window already active with
/// the same conversation on screen sends nothing, so typing does not send one per
/// keystroke. The one exception is input after a quiet spell: the daemon takes a Mac
/// not heard from for `macIdle` to be one the person has left, so the first key or
/// click after that long says otherwise, once.
///
/// It reports; it decides nothing. Where a need goes is the daemon's (FR-012).
@MainActor
final class PresenceReporter {
    /// `presence/report`, with what is watched and whether this window is in front.
    typealias Report = @MainActor (UUID?, Bool) async -> Void

    private let report: Report
    private var last: (watching: UUID?, active: Bool)?
    private var lastReportedAt = Date.distantPast
    private var watching: UUID?
    private var observers: [any NSObjectProtocol] = []
    private var inputMonitor: Any?

    /// Longer than this between reports, and the next input is worth a fresh one. Half
    /// the daemon's idle threshold, so a person who keeps working is never taken for
    /// one who has gone.
    private let quietSpell: TimeInterval = AttentionThresholds.standard.macIdle / 2

    init(report: @escaping Report) {
        self.report = report
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.send() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.send() }
            },
        ]
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.sawInput() }
            return event
        }
        send(force: true)
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
    }

    /// Which conversation is on screen now. Nil for a project page, a workflow, or
    /// nothing.
    func watching(_ agentID: UUID?) {
        watching = agentID
        send()
    }

    /// A fresh connection is a fresh record on the daemon's side, so say it all again.
    func connected() {
        send(force: true)
    }

    private func sawInput() {
        guard Date().timeIntervalSince(lastReportedAt) > quietSpell else { return }
        send(force: true)
    }

    private func send(force: Bool = false) {
        let active = NSApp.isActive
        let now = (watching: active ? watching : nil, active: active)
        if !force, let last, last.watching == now.watching, last.active == now.active { return }
        last = now
        lastReportedAt = Date()
        Task { await report(now.watching, now.active) }
    }
}
