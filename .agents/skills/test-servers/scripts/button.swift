import ApplicationServices
import Foundation
// button.swift <pid> <label>: press the AXButton whose title or description is exactly the
// label, and say whether it was enabled. ui.swift's press takes the first pressable match,
// which for "Send" is the menu bar's "Send to Claude"; this takes buttons only.
let a = CommandLine.arguments
guard a.count == 3 else { print("usage: button.swift <pid> <label>"); exit(2) }
let app = AXUIElementCreateApplication(pid_t(a[1])!)
func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, n as CFString, &v); return v }
func find(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
    if (attr(e, kAXRoleAttribute) as? String) == "AXButton",
       (attr(e, kAXTitleAttribute) as? String) == a[2] || (attr(e, kAXDescriptionAttribute) as? String) == a[2] { return e }
    if d > 40 { return nil }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { if let f = find(c, d + 1) { return f } }
    return nil
}
guard let b = find(app, 0) else { print("no button \(a[2])"); exit(1) }
let enabled = attr(b, kAXEnabledAttribute) as? Bool ?? false
print("enabled: \(enabled) press:", AXUIElementPerformAction(b, kAXPressAction as CFString).rawValue)
exit(enabled ? 0 : 1)
