// Look at, and press, one app's window — by pid, without taking focus.
//
//   swift ui.swift windows <pid>              window ids and bounds (for screencapture -l)
//   swift ui.swift dump <pid> [depth]         the accessibility tree, indented
//   swift ui.swift find <pid> <text>          every element whose label holds <text>
//   swift ui.swift press <pid> <text>         AXPress the first one that matches
//   swift ui.swift set <pid> <text> <value>   type into the field labelled <text>
//
// AX actions go to the element, not to the pointer, so nothing is stolen from
// whatever the user is doing. Needs Accessibility permission for the process
// that runs this (System Settings › Privacy & Security › Accessibility).
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

let arguments = CommandLine.arguments
guard arguments.count >= 3, let pid = pid_t(arguments[2]) else {
    print("usage: ui.swift windows|dump|find|press|set <pid> [args]")
    exit(2)
}
let verb = arguments[1]

if verb == "windows" {
    let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
    let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
    for window in list where (window[kCGWindowOwnerPID as String] as? pid_t) == pid {
        let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let id = window[kCGWindowNumber as String] as? Int ?? 0
        let name = window[kCGWindowName as String] as? String ?? ""
        let w = bounds["Width"] ?? 0, h = bounds["Height"] ?? 0
        print("\(id)\t\(Int(w))x\(Int(h))\t\(name)")
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
    let needle = arguments[3].lowercased()
    var matches: [AXUIElement] = []
    walk(app, depth: 0, limit: 30) { element, _ in
        if label(element).lowercased().contains(needle) { matches.append(element) }
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
