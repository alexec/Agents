import AgentsKitCore
import AppKit

/// Turns the next beachball into a stack (#237).
///
/// The window locked up under load and the system wrote nothing: spindump does not sample
/// when the machine is that busy. So the window watches its own main thread
/// (`HangWatchdog`) and, when it stops answering for two seconds, writes every thread's
/// stack to `~/Library/Logs/Agents/hangs/` in its container, with what the person last
/// did: clicks (the view under the pointer), keys (which kind, never the characters) and
/// the waits `Perf` times.
@MainActor
enum HangReporter {
    private static var watchdog: HangWatchdog?
    private static var monitor: Any?
    private static var observers: [Any] = []

    static func install() {
        guard watchdog == nil else { return }
        let watchdog = HangWatchdog.watchingMain()
        watchdog.start()
        self.watchdog = watchdog
        // `NSApp` is not there yet while the `App` is being made.
        DispatchQueue.main.async { watchEvents() }
    }

    private static func watchEvents() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
            HangWatchdog.note(describe(event))
            return event
        }
        // A hang that starts while the window is behind another is worth telling apart.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
                HangWatchdog.note("app became active")
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { _ in
                HangWatchdog.note("app went to the background")
            },
        ]
    }

    private static func describe(_ event: NSEvent) -> String {
        switch event.type {
        case .keyDown:
            let modifiers = event.modifierFlags.intersection([.command, .control, .option])
            if !modifiers.isEmpty, let key = event.charactersIgnoringModifiers {
                return "key \(shortcut(modifiers))\(key)"
            }
            return "key " + (named[event.keyCode] ?? "typing")
        default:
            let button = event.type == .rightMouseDown ? "right-click" : "click"
            guard let window = event.window else { return "\(button) outside a window" }
            let view = window.contentView?.hitTest(event.locationInWindow)
            let name = view.map { String(describing: type(of: $0)) } ?? "nothing"
            return "\(button) \(name) in \(window.title.isEmpty ? String(describing: type(of: window)) : window.title)"
        }
    }

    private static func shortcut(_ modifiers: NSEvent.ModifierFlags) -> String {
        (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.command) ? "⌘" : "")
    }

    /// Keys that say what the person did; the rest is typing.
    private static let named: [UInt16: String] = [
        36: "return", 48: "tab", 51: "delete", 53: "escape", 76: "enter",
        123: "left", 124: "right", 125: "down", 126: "up",
    ]
}
