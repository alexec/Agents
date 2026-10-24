// Look at, and press, one app's window — by pid, without taking focus.
//
//   swift ui.swift windows <pid>              window ids, bounds, name and on|off (for screencapture -l)
//   swift ui.swift selftest                   check that `windows` finds a window not on screen
//   swift ui.swift dump <pid> [depth]         the accessibility tree, indented
//   swift ui.swift find <pid> <text>          every element whose label holds <text>
//   swift ui.swift press <pid> <text>         AXPress the LAST one that matches (innermost);
//                                             make <text> unique, `find` lists them in order;
//                                             `=<text>` matches the whole label only
//   swift ui.swift set <pid> <text> <value>   type into the field labelled <text>
//
// AX actions go to the element, not to the pointer, so nothing is stolen from
// whatever the user is doing. Needs Accessibility permission for the process
// that runs this (System Settings › Privacy & Security › Accessibility).
//
// A window opened behind (`open -g`) while the user's front app is full screen goes to
// the desktop's Space, not theirs (#1131). It is "off": `screencapture -l` still takes
// it, but AX lists no AXWindow for it, so dump, find, press and set see only the menu bar.
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func string(_ element: AXUIElement, _ name: String) -> String? {
    guard let value = attribute(element, name) else { return nil }
    if let text = value as? String { return text }
    if CFGetTypeID(value) == AXValueGetTypeID() { return nil }
    return nil
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func label(_ element: AXUIElement) -> String {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute]
        .compactMap { string(element, $0 as String) }
        .filter { !$0.isEmpty }
        .joined(separator: " | ")
}

func role(_ element: AXUIElement) -> String { string(element, kAXRoleAttribute as String) ?? "?" }

func frame(_ element: AXUIElement) -> CGRect? {
    guard let p = attribute(element, kAXPositionAttribute as String),
          let s = attribute(element, kAXSizeAttribute as String) else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}

func walk(_ element: AXUIElement, depth: Int, limit: Int, visit: (AXUIElement, Int) -> Bool) {
    if !visit(element, depth) { return }
    if depth >= limit { return }
    for child in children(element) { walk(child, depth: depth + 1, limit: limit, visit: visit) }
}

/// The pid's ordinary windows (layer 0), on this Space or not: a window on another Space,
/// or behind a full-screen app, is not "on screen" and is still the app's window (#1131).
func windows(of pid: pid_t) -> [(id: Int, width: Int, height: Int, name: String, on: Bool)] {
    let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { window in
        guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
              (window[kCGWindowLayer as String] as? Int) == 0 else { return nil }
        let bounds = (window[kCGWindowBounds as String] as CFTypeRef?)
            .flatMap { CGRect(dictionaryRepresentation: $0 as! CFDictionary) } ?? .zero
        return (id: window[kCGWindowNumber as String] as? Int ?? 0,
                width: Int(bounds.width), height: Int(bounds.height),
                name: window[kCGWindowName as String] as? String ?? "",
                on: window[kCGWindowIsOnscreen as String] as? Bool ?? false)
    }
}

let arguments = CommandLine.arguments
if arguments.count == 2, arguments[1] == "selftest" {
    // A window of this process's own, never shown (alpha 0, ordered out): `windows` must
    // still find it, as it must find a scratch window on another Space (#1131).
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.alphaValue = 0
    // The window server learns of each order only as the run loop turns.
    window.orderBack(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    window.orderOut(nil)
    RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    let found = windows(of: getpid()).first { $0.id == window.windowNumber }
    guard let found, !found.on, found.width == 400 else {
        FileHandle.standardError.write(Data("selftest: windows did not list a window that is not on screen\n".utf8))
        exit(1)
    }
    print("selftest: ok")
    exit(0)
}
guard arguments.count >= 3, let pid = pid_t(arguments[2]) else {
    print("usage: ui.swift windows|dump|find|press|set <pid> [args]")
    exit(2)
}
let verb = arguments[1]

if verb == "windows" {
    for window in windows(of: pid) {
        print("\(window.id)\t\(window.width)x\(window.height)\t\(window.name)\t\(window.on ? "on" : "off")")
    }
    exit(0)
}

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("no Accessibility permission for this process\n".utf8))
    exit(3)
}

let app = AXUIElementCreateApplication(pid)

switch verb {
case "dump":
    let limit = arguments.count > 3 ? Int(arguments[3]) ?? 12 : 12
    walk(app, depth: 0, limit: limit) { element, depth in
        let text = label(element)
        let box = frame(element).map { " @\(Int($0.origin.x)),\(Int($0.origin.y)) \(Int($0.width))x\(Int($0.height))" } ?? ""
        print(String(repeating: "  ", count: depth) + role(element) + (text.isEmpty ? "" : " · " + text) + box)
        return true
    }

case "find", "press":
    guard arguments.count > 3 else { print("need text to match"); exit(2) }
    // `=Show` is the label "Show" and nothing longer: no "Show Inspector" in a menu.
    let exact = arguments[3].hasPrefix("=")
    let needle = (exact ? String(arguments[3].dropFirst()) : arguments[3]).lowercased()
    var matches: [AXUIElement] = []
    walk(app, depth: 0, limit: 30) { element, _ in
        let text = label(element).lowercased()
        if exact ? text == needle : text.contains(needle) { matches.append(element) }
        return true
    }
    if verb == "find" {
        for element in matches {
            let box = frame(element).map { " @\(Int($0.origin.x)),\(Int($0.origin.y))" } ?? ""
            print("\(role(element)) · \(label(element))\(box)")
        }
        exit(matches.isEmpty ? 1 : 0)
    }
    // Press the innermost match that will take a press: a row's label is often a
    // child of the button that actually does something.
    for element in matches.reversed() {
        var actions: CFArray?
        AXUIElementCopyActionNames(element, &actions)
        let names = (actions as? [String]) ?? []
        if names.contains(kAXPressAction as String) {
            if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                print("pressed: \(role(element)) · \(label(element))")
                exit(0)
            }
        }
        // Walk up: the label may be inside the button.
        var parent = attribute(element, kAXParentAttribute as String)
        var hops = 0
        while let current = parent, hops < 4 {
            let up = current as! AXUIElement
            var upActions: CFArray?
            AXUIElementCopyActionNames(up, &upActions)
            if ((upActions as? [String]) ?? []).contains(kAXPressAction as String),
               AXUIElementPerformAction(up, kAXPressAction as CFString) == .success {
                print("pressed parent: \(role(up)) · \(label(up))")
                exit(0)
            }
            parent = attribute(up, kAXParentAttribute as String)
            hops += 1
        }
    }
    print("nothing pressable matched \(arguments[3])")
    exit(1)

case "select":
    // A sidebar row is selected rather than pressed: set AXSelected on the nearest
    // row above the first matching label. Nothing is clicked and focus stays put.
    guard arguments.count > 3 else { print("need text to match"); exit(2) }
    let wanted = arguments[3].lowercased()
    var found: AXUIElement?
    walk(app, depth: 0, limit: 30) { element, _ in
        if found == nil, label(element).lowercased().contains(wanted) { found = element }
        return found == nil
    }
    var candidate = found.map { Optional($0) } ?? nil
    var hops = 0
    while let current = candidate, hops < 6 {
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(current, kAXSelectedAttribute as CFString, &settable) == .success,
           settable.boolValue,
           AXUIElementSetAttributeValue(current, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success {
            print("selected: \(role(current)) · \(label(current))")
            exit(0)
        }
        candidate = attribute(current, kAXParentAttribute as String).map { $0 as! AXUIElement }
        hops += 1
    }
    print("nothing selectable matched \(arguments[3])")
    exit(1)

case "unfold", "fold":
    // An outline row (a folder in the sidebar, a disclosure group) folded or unfolded
    // by AXDisclosing on the nearest row above the first matching label. No click.
    guard arguments.count > 3 else { print("need text to match"); exit(2) }
    let wanted = arguments[3].lowercased()
    var found: AXUIElement?
    walk(app, depth: 0, limit: 30) { element, _ in
        if found == nil, label(element).lowercased().contains(wanted) { found = element }
        return found == nil
    }
    var candidate = found
    var hops = 0
    while let current = candidate, hops < 6 {
        if role(current) == "AXRow" {
            let value: CFBoolean = verb == "unfold" ? kCFBooleanTrue : kCFBooleanFalse
            let result = AXUIElementSetAttributeValue(current, "AXDisclosing" as CFString, value)
            print(result == .success ? "\(verb)ed: \(label(found!))" : "could not \(verb): \(result.rawValue)")
            exit(result == .success ? 0 : 1)
        }
        candidate = attribute(current, kAXParentAttribute as String).map { $0 as! AXUIElement }
        hops += 1
    }
    print("no row matched \(arguments[3])")
    exit(1)

case "set":
    guard arguments.count > 4 else { print("need text and value"); exit(2) }
    let needle = arguments[3].lowercased()
    var done = false
    walk(app, depth: 0, limit: 30) { element, _ in
        if done { return false }
        if label(element).lowercased().contains(needle) || role(element) == "AXTextField" || role(element) == "AXTextArea" {
            if AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, arguments[4] as CFTypeRef) == .success {
                print("set: \(role(element))")
                done = true
                return false
            }
        }
        return true
    }
    exit(done ? 0 : 1)

default:
    print("unknown verb \(verb)")
    exit(2)
}
