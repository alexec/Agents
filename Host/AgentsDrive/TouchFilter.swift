// Pause on touch (#3004, US3, research R2): a listen-only CGEventTap that hears the
// person's own mouse and keyboard while this helper runs, and says {"touch":true} the
// moment one arrives. Events this binary posted carry agentsDriveMarker
// (InputSynthesis.swift) and are not a touch. The tap needs the same Accessibility grant
// the rest of this helper does; until it is granted there is no tap, and start() tries
// again on the next command.
import CoreGraphics
import Foundation

/// What the tap has heard, read by the command loop and the tap's own thread.
final class TouchWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var tap: CFMachPort?
    /// Says the next touch: set by every command, cleared once a touch is said, so a
    /// person moving the mouse about says it once, not hundreds of times.
    private var armed = false
    private var touched = false
    /// When this binary last posted an event. Moving the pointer to click can make the
    /// system post a mouse move of its own, without the marker; one that soon after is ours.
    private var lastPost = Date.distantPast

    /// Called at each command: starts the tap if it is not running, and says the next touch.
    func arm() {
        start()
        lock.lock()
        armed = true
        touched = false
        lock.unlock()
    }

    /// Whether the person touched the mouse or keyboard since the command began.
    var isTouched: Bool {
        lock.lock()
        defer { lock.unlock() }
        return touched
    }

    func notePost() {
        lock.lock()
        lastPost = Date()
        lock.unlock()
    }

    fileprivate func heard(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            lock.unlock()
            return
        }
        if event.getIntegerValueField(.eventSourceUserData) == agentsDriveMarker { return }
        lock.lock()
        if type == .mouseMoved, Date().timeIntervalSince(lastPost) < 0.2 {
            lock.unlock()
            return
        }
        touched = true
        let say = armed
        armed = false
        lock.unlock()
        if say { reply(["touch": true]) }
    }

    private func start() {
        lock.lock()
        defer { lock.unlock() }
        guard tap == nil else { return }
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .rightMouseDragged, .scrollWheel, .keyDown, .flagsChanged,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let made = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: { _, type, event, _ in
                                               touchWatch.heard(type, event)
                                               return Unmanaged.passUnretained(event)
                                           }, userInfo: nil) else { return }
        tap = made
        // Handed to the tap's own thread, and only read there after this.
        nonisolated(unsafe) let port = made
        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "touch"
        thread.start()
    }
}

let touchWatch = TouchWatch()
