import AgentsKitCore
import AppKit
import os

/// What sends the window back to its hosts at once rather than when its backoff says:
/// the Mac waking, or the network changing (#82).
@MainActor
final class WakeAndNetwork {
    static let log = Logger(subsystem: "com.alexecollins.agents", category: "reconnect")

    private var triggers: ReconnectTriggers?
    private var debugHook: (any NSObjectProtocol)?

    /// Starts once; `goBack` is told each time, on the main actor.
    func start(_ goBack: @escaping @MainActor (ReconnectTriggers.Reason) -> Void) {
        guard triggers == nil else { return }
        let wake = ReconnectTriggers.Wake(center: NSWorkspace.shared.notificationCenter,
                                          name: NSWorkspace.didWakeNotification)
        // Both are delivered on the main queue.
        let triggers = ReconnectTriggers(wakes: [wake]) { reason in
            MainActor.assumeIsolated { goBack(reason) }
        }
        self.triggers = triggers
        triggers.start()
        #if DEBUG
        // A scratch walk's way to say the Mac woke or the network changed, which nothing
        // else can make happen on cue: `com.alexecollins.agents.debug.reconnect`, posted
        // with `wake` or `network` as its object. Debug builds only.
        debugHook = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.alexecollins.agents.debug.reconnect"), object: nil, queue: .main
        ) { note in
            guard let reason = (note.object as? String).flatMap(ReconnectTriggers.Reason.init) else { return }
            triggers.fire(reason)
        }
        #endif
    }
}
