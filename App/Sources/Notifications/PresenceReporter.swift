import AgentsKit
import AppKit
import CoreGraphics
import Foundation

/// Tells the daemon where the person is, as far as this window can know: whether they
/// are at the Mac, and which conversation this window is showing them.
///
/// Two different facts, and the first is **not** whether this app is frontmost. At the
/// Mac means the machine is in use — unlocked, with input inside `macIdle` — whichever
/// app is in front; that is what lets the Mac's own banner reach a person who is in
/// another app, which is the whole of Slice A. Watching is the narrower one: this
/// window in front, showing that conversation. Reported as `active` and `watching`.
///
/// A report is sent on a **change**, never on a timer. System-wide input is not an
/// event this process is handed, so it is sampled — but a sample that finds nothing
/// changed sends nothing, and the daemon hears from a Mac that is simply in use about
/// once per `macIdle`, which is what keeps its record fresh.
///
/// It reports; it decides nothing. Where a need goes is the daemon's (FR-012).
@MainActor
final class PresenceReporter {
    typealias Report = @MainActor (UUID?, Bool) async -> Void

    private let report: Report
    private let macIdle = AttentionThresholds.standard.macIdle
    private var last: (watching: UUID?, active: Bool)?
    private var lastReportedAt = Date.distantPast
    private var watching: UUID?
    private var observers: [any NSObjectProtocol] = []
    private var inputMonitor: Any?
    private var sampler: Timer?

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
            MainActor.assumeIsolated { self?.send() }
            return event
        }
        // Sampled at a third of the idle threshold, so a Mac in use is heard from well
        // inside it and a Mac left alone is noticed within it.
        sampler = Timer.scheduledTimer(withTimeInterval: macIdle / 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.send() }
        }
        send(force: true)
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        sampler?.invalidate()
        sampler = nil
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

    private func send(force: Bool = false) {
        let inUse = MacActivity.isInUse(within: macIdle)
        let now = (watching: NSApp.isActive && inUse ? watching : nil, active: inUse)
        // Unchanged, and heard from recently enough: nothing to say. The daemon ages a
        // record past `macIdle`, so a Mac still in use is told again before that.
        let stale = Date().timeIntervalSince(lastReportedAt) > macIdle / 2
        if !force, !stale, let last, last.watching == now.watching, last.active == now.active { return }
        last = now
        lastReportedAt = Date()
        Task { await report(now.watching, now.active) }
    }
}

/// Whether the person is at this Mac: the screen is not locked, and something — in any
/// app — was typed, clicked or scrolled recently. Read from the session, not from this
/// app, because a person in another app is still at the Mac.
enum MacActivity {
    static func isInUse(within idle: TimeInterval) -> Bool {
        !isLocked && secondsSinceInput < idle
    }

    private static var isLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    private static var secondsSinceInput: TimeInterval {
        // Any input event, across the whole session: the "any" type is every bit set.
        let anyInput = CGEventType(rawValue: UInt32.max) ?? .null
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}
