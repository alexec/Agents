import ApplicationServices
import Foundation
// menu.swift <pid> <menu button label> <submenu> [<item>]: open a menu button (e.g. the
// sidebar's "New project"), then press an item in it, or an item inside a submenu of it.
//   swift menu.swift $APP_PID "New project" "127.0.0.1" "Choose Folder…"
//   swift menu.swift $APP_PID "New project" "Add a server…"
let a = CommandLine.arguments
guard a.count >= 4 else { print("usage: menu.swift <pid> <menu button> <item or submenu> [item]"); exit(2) }
let app = AXUIElementCreateApplication(pid_t(a[1])!)
func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, n as CFString, &v); return v }
func role(_ e: AXUIElement) -> String { attr(e, kAXRoleAttribute) as? String ?? "" }
func label(_ e: AXUIElement) -> String { [attr(e, kAXTitleAttribute), attr(e, kAXDescriptionAttribute)].compactMap { $0 as? String }.first { !$0.isEmpty } ?? "" }
func find(_ e: AXUIElement, _ d: Int = 0, _ test: (AXUIElement) -> Bool) -> AXUIElement? {
    if test(e) { return e }
    if d > 40 { return nil }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { if let f = find(c, d + 1, test) { return f } }
    return nil
}
guard let button = find(app, 0, { role($0) == "AXMenuButton" && label($0).hasPrefix(a[2]) }) else { print("no menu button \(a[2])"); exit(1) }
AXUIElementPerformAction(button, kAXPressAction as CFString)
Thread.sleep(forTimeInterval: 0.5)
let isItem: (AXUIElement, String) -> Bool = { role($0) == "AXMenuItem" && (attr($0, kAXTitleAttribute) as? String) == $1 }
guard let first = find(app, 0, { isItem($0, a[3]) }) else { print("no item \(a[3])"); exit(1) }
if a.count == 4 { print("press:", AXUIElementPerformAction(first, kAXPressAction as CFString).rawValue); exit(0) }
AXUIElementPerformAction(first, kAXPressAction as CFString)
Thread.sleep(forTimeInterval: 0.5)
guard let item = find(first, 0, { isItem($0, a[4]) }) else { print("no item \(a[4]) in \(a[3])"); exit(1) }
print("press:", AXUIElementPerformAction(item, kAXPressAction as CFString).rawValue)
