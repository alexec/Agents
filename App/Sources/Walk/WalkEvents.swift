#if DEBUG
import AppKit
import Foundation

/// A click or a key made in process (#1172), for what has no accessibility action: a
/// SwiftUI tap gesture (a folder's heading folds on one), Return in the prompt. The event
/// is handed to the view itself, never posted to the window server or HID, and the window
/// is never made key, so nothing reaches another app or takes the focus from one.
@MainActor
enum WalkEvents {
    /// A click at a point in the window, in its points from its top left.
    static func click(_ window: NSWindow, at point: CGPoint, count: Int) throws -> String {
        guard let frameView = window.contentView?.superview else { throw WalkError("no window to click") }
        let local = CGPoint(x: point.x, y: window.frame.height - point.y)
        guard let view = frameView.hitTest(local) else { throw WalkError("nothing at \(Int(point.x)),\(Int(point.y))") }
        for click in 1...max(1, count) {
            guard let down = mouse(.leftMouseDown, at: local, in: window, count: click),
                  let up = mouse(.leftMouseUp, at: local, in: window, count: click) else { throw WalkError("no event") }
            // A control or a table follows the mouse in a loop of its own until the button
            // comes up: the up waits in this app's queue for it. Else it is handed over too.
            NSApp.postEvent(up, atStart: false)
            window.sendEvent(down)
            if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true),
               queued.timestamp == up.timestamp {
                window.sendEvent(up)
            }
        }
        return "clicked \(view.className) at \(Int(point.x)),\(Int(point.y)); active \(NSApp.isActive), key \(window.isKeyWindow)"
    }

    private static func mouse(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow, count: Int) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count,
                           pressure: type == .leftMouseDown ? 1 : 0)
    }

    /// A key, down and up, to the window's first responder: `return`, `escape`, `tab`,
    /// `left`, `right`, `up`, `down`, `delete`, `pageup`, `pagedown`, `home`, `end`, or one
    /// character; with `cmd`, `shift`, `option`, `control`.
    static func key(_ window: NSWindow, _ name: String, modifiers: [String]) throws -> String {
        let named: [String: (String, UInt16)] = [
            "return": ("\r", 36), "escape": ("\u{1b}", 53), "tab": ("\t", 48), "delete": ("\u{7f}", 51),
            "space": (" ", 49),
            "left": (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123), "right": (String(UnicodeScalar(NSRightArrowFunctionKey)!), 124),
            "down": (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125), "up": (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126),
            "pageup": (String(UnicodeScalar(NSPageUpFunctionKey)!), 116), "pagedown": (String(UnicodeScalar(NSPageDownFunctionKey)!), 121),
            "home": (String(UnicodeScalar(NSHomeFunctionKey)!), 115), "end": (String(UnicodeScalar(NSEndFunctionKey)!), 119),
        ]
        guard let (characters, code) = named[name.lowercased()] ?? (name.count == 1 ? (name, 0) : nil) else {
            throw WalkError("no key \(name)")
        }
        var flags: NSEvent.ModifierFlags = []
        for modifier in modifiers {
            switch modifier {
            case "cmd", "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "option", "alt": flags.insert(.option)
            case "control", "ctrl": flags.insert(.control)
            default: throw WalkError("no modifier \(modifier)")
            }
        }
        if ["left", "right", "up", "down"].contains(name.lowercased()) { flags.formUnion([.numericPad, .function]) }
        let make = { (type: NSEvent.EventType) in
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: characters,
                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
        }
        guard let down = make(.keyDown), let up = make(.keyUp) else { throw WalkError("no event") }
        // A shortcut goes to the window's views and then the menu bar, as AppKit sends one.
        if flags.contains(.command) {
            if window.performKeyEquivalent(with: down) || NSApp.mainMenu?.performKeyEquivalent(with: down) == true {
                return "shortcut \(modifiers.joined(separator: "+"))+\(name)"
            }
        }
        // The keys that read the transcript are taken by a local monitor (#2210), which sees
        // only what comes through the app's queue: posted, not handed to the window.
        if ["pageup", "pagedown", "home", "end"].contains(name.lowercased()) {
            NSApp.postEvent(up, atStart: true)
            NSApp.postEvent(down, atStart: true)
            return "key \(name) posted to the app"
        }
        window.sendEvent(down)
        window.sendEvent(up)
        return "key \(name) to \(window.firstResponder?.className ?? "nothing")"
    }
}
#endif
