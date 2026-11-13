#if DEBUG
import AppKit
import Foundation
import WebKit

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
        // A web view (a view's page, the diff sheet, an HTML page) takes a window's first
        // click only when the window is key (#4137): `acceptsFirstMouse` says no, so the
        // window keeps the click. It is handed to the web view itself, which sends it on to
        // its page.
        if let web = webView(at: view) {
            for click in 1...max(1, count) {
                guard let down = mouse(.leftMouseDown, at: local, in: window, count: click),
                      let up = mouse(.leftMouseUp, at: local, in: window, count: click) else { throw WalkError("no event") }
                web.mouseDown(with: down)
                web.mouseUp(with: up)
            }
            return "clicked \(web.className) at \(Int(point.x)),\(Int(point.y)), handed to it; active \(NSApp.isActive), key \(window.isKeyWindow)"
        }
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

    /// A drag from one point to another with the button down (#5155), as a person selects
    /// words. Handed to the view under the start, as a web view's click is: the window is
    /// not key, and would keep a first click. The drags and the up wait in this app's queue
    /// for the view's own loop, which follows the mouse until the button comes up.
    static func drag(_ window: NSWindow, from: CGPoint, to: CGPoint) throws -> String {
        guard let frameView = window.contentView?.superview else { throw WalkError("no window to drag in") }
        let start = CGPoint(x: from.x, y: window.frame.height - from.y)
        let end = CGPoint(x: to.x, y: window.frame.height - to.y)
        guard let view = frameView.hitTest(start) else { throw WalkError("nothing at \(Int(from.x)),\(Int(from.y))") }
        guard let down = mouse(.leftMouseDown, at: start, in: window, count: 1) else { throw WalkError("no event") }
        let steps = 8
        for step in 1...steps {
            let part = Double(step) / Double(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * part, y: start.y + (end.y - start.y) * part)
            if let moved = mouse(.leftMouseDragged, at: point, in: window, count: 1) {
                NSApp.postEvent(moved, atStart: false)
            }
        }
        guard let up = mouse(.leftMouseUp, at: end, in: window, count: 1) else { throw WalkError("no event") }
        NSApp.postEvent(up, atStart: false)
        view.mouseDown(with: down)
        // What the view's loop did not take is not left for the next walk step.
        while NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantPast,
                              inMode: .default, dequeue: true) != nil {}
        return "dragged in \(view.className) from \(Int(from.x)),\(Int(from.y)) to \(Int(to.x)),\(Int(to.y))"
    }

    /// The web view the view is, or is in.
    static func webView(at view: NSView) -> WKWebView? {
        var current: NSView? = view
        while let next = current {
            if let web = next as? WKWebView { return web }
            current = next.superview
        }
        return nil
    }

    private static func mouse(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow, count: Int) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count,
                           pressure: type == .leftMouseUp ? 0 : 1)
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
