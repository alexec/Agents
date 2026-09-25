import ApplicationServices
import Foundation
// field.swift <pid> <current value prefix> <new value> [--confirm]: set the first text field
// whose value starts with the prefix ("" matches any), and with --confirm press Return in it
// (AXConfirm). Good for the server folder sheet's path and the Add a server name.
//
// Not for the prompt box: its value changes on screen but not in its SwiftUI binding, so
// Send stays disabled. Send a turn with server-rpc.sh instead.
let a = CommandLine.arguments
guard a.count >= 4 else { print("usage: field.swift <pid> <prefix> <value> [--confirm]"); exit(2) }
let app = AXUIElementCreateApplication(pid_t(a[1])!)
func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, n as CFString, &v); return v }
func find(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
    if (attr(e, kAXRoleAttribute) as? String) == "AXTextField", (attr(e, kAXValueAttribute) as? String ?? "").hasPrefix(a[2]) { return e }
    if d > 40 { return nil }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { if let f = find(c, d + 1) { return f } }
    return nil
}
guard let field = find(app, 0) else { print("no text field starting \"\(a[2])\""); exit(1) }
AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
print("set:", AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, a[3] as CFString).rawValue)
if a.contains("--confirm") { print("confirm:", AXUIElementPerformAction(field, "AXConfirm" as CFString).rawValue) }
