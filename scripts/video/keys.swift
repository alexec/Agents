// Types into, sizes and drives one app's window by pid, without taking focus from the front app.
//
//   keys type <pid> <field> <text> [ms]  focus the text field or area whose placeholder or label
//                                        holds <field> ("" for the first one, "@AXTextArea" for
//                                        the first of that role, "after:Other" for the first one
//                                        after the text "Other"), then type <text> a key at a
//                                        time, <ms> apart (default 45)
//   keys key <pid> <return|escape|delete|select-all>
//   keys size <pid> <width> <height> [x y] the app's biggest window, in points
//   keys menu <pid> <menu> <item>        press a menu bar item, e.g. "View" "Open in Browser"
//
// AXValue on a SwiftUI field never reaches its binding, so typing posts key events to the pid
// (CGEvent.postToPid), which does. Nothing reaches the front app.
import ApplicationServices
import Foundation

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func text(_ element: AXUIElement, _ name: String) -> String { (attribute(element, name) as? String) ?? "" }
func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}
func find(_ element: AXUIElement, depth: Int = 0, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
    if match(element) { return element }
    if depth > 40 { return nil }
    for child in children(element) {
        if let found = find(child, depth: depth + 1, match) { return found }
    }
    return nil
}

func post(_ pid: pid_t, key: CGKeyCode, unicode: String? = nil, flags: CGEventFlags = []) {
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down) else { continue }
        if let unicode {
            let units = Array(unicode.utf16)
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        event.flags = flags
        event.postToPid(pid)
        usleep(8_000)
    }
}

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[2]) else {
    print("usage: keys type|key|size|menu <pid> …"); exit(2)
}
let app = AXUIElementCreateApplication(pid)

switch args[1] {
case "type":
    guard args.count >= 5 else { print("need a field and text"); exit(2) }
    let needle = args[3].lowercased()
    let delay = args.count > 5 ? UInt32(args[5]) ?? 45 : 45
    var lastText = ""
    let field = find(app) { element in
        let role = text(element, kAXRoleAttribute as String)
        if role == "AXStaticText" { lastText = text(element, kAXValueAttribute as String).lowercased() }
        guard role == "AXTextField" || role == "AXTextArea" else { return false }
        if needle.hasPrefix("after:") { return lastText == needle.dropFirst(6) }
        if needle.isEmpty { return true }
        if needle.hasPrefix("@") { return role.lowercased() == needle.dropFirst() }
        return [kAXPlaceholderValueAttribute as String, kAXDescriptionAttribute as String,
                kAXTitleAttribute as String, kAXHelpAttribute as String]
            .contains { text(element, $0).lowercased().contains(needle) }
    }
    guard let field else { print("no field \(args[3])"); exit(1) }
    AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    usleep(150_000)
    for character in args[4] {
        if character == "\n" { post(pid, key: 36, unicode: "\r") } else { post(pid, key: 0, unicode: String(character)) }
        usleep(delay * 1000)
    }
    print("typed")

case "key":
    guard args.count >= 4 else { print("need a key"); exit(2) }
    switch args[3] {
    case "return": post(pid, key: 36, unicode: "\r")
    case "escape": post(pid, key: 53)
    case "delete": post(pid, key: 51)
    case "select-all": post(pid, key: 0, unicode: "a", flags: .maskCommand)
    default: print("unknown key \(args[3])"); exit(2)
    }

case "size":
    guard args.count >= 5, let w = Double(args[3]), let h = Double(args[4]) else { print("need width and height"); exit(2) }
    let windows = (attribute(app, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
    guard let window = windows.first(where: { text($0, kAXSubroleAttribute as String) == "AXStandardWindow" }) ?? windows.first else {
        print("no window"); exit(1)
    }
    if args.count >= 7, let x = Double(args[5]), let y = Double(args[6]) {
        var point = CGPoint(x: x, y: y)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &point)!)
    }
    var size = CGSize(width: w, height: h)
    let result = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!)
    print(result == .success ? "sized" : "could not size: \(result.rawValue)")

case "menu":
    guard args.count >= 5 else { print("need a menu and an item"); exit(2) }
    guard let bar = attribute(app, kAXMenuBarAttribute as String) else { print("no menu bar"); exit(1) }
    let barElement = bar as! AXUIElement
    guard let menu = children(barElement).first(where: { text($0, kAXTitleAttribute as String) == args[3] }),
          let list = children(menu).first,
          let item = children(list).first(where: { text($0, kAXTitleAttribute as String) == args[4] }) else {
        print("no menu item \(args[3]) ▸ \(args[4])"); exit(1)
    }
    print(AXUIElementPerformAction(item, kAXPressAction as CFString) == .success ? "pressed" : "could not press")

default:
    print("unknown verb \(args[1])"); exit(2)
}
