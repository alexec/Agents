// The accessibility half of agents-drive (#3004, US1): finding the named app's process,
// reading its tree, and pressing an element by label. Ported from
// .agents/skills/run-app/scripts/ui.swift's `dump`/`find`/`press`, the scratch driver this
// binary replaces for a real run (research R1): same walk, same label, same press-the-
// innermost-match, but shipped as a signed helper Accessibility can be granted to once.
import AppKit
import ApplicationServices
import Foundation

func axAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func axString(_ element: AXUIElement, _ name: String) -> String? {
    axAttribute(element, name) as? String
}

func axChildren(_ element: AXUIElement) -> [AXUIElement] {
    (axAttribute(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func axLabel(_ element: AXUIElement) -> String {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute]
        .compactMap { axString(element, $0 as String) }
        .filter { !$0.isEmpty }
        .joined(separator: " | ")
}

func axRole(_ element: AXUIElement) -> String { axString(element, kAXRoleAttribute as String) ?? "?" }

func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let p = axAttribute(element, kAXPositionAttribute as String),
          let s = axAttribute(element, kAXSizeAttribute as String) else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    // swiftlint:disable:next force_cast
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    // swiftlint:disable:next force_cast
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}

func axWalk(_ element: AXUIElement, depth: Int, limit: Int, visit: (AXUIElement, Int) -> Bool) {
    if !visit(element, depth) { return }
    if depth >= limit { return }
    for child in axChildren(element) { axWalk(child, depth: depth + 1, limit: limit, visit: visit) }
}

/// The running app named on the menu bar, by NSRunningApplication.localizedName (what a
/// person reads there, and what `app` in a drive_screen call names).
func pid(ofApp name: String) -> pid_t? {
    NSWorkspace.shared.runningApplications
        .first { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }
        .map { $0.processIdentifier }
}

/// Brings the app named to the front and says why not when it cannot: the
/// synthetic mouse and keyboard post to the whole session (InputSynthesis.swift), so they
/// land in whatever app is frontmost. `type`, `key` and `click x,y` go only after this
/// returns nil, so they reach the app the call names and the transcript's words are true.
func frontmost(app name: String) -> String? {
    guard let pid = pid(ofApp: name),
          let running = NSRunningApplication(processIdentifier: pid) else {
        return "no running app named \"\(name)\"."
    }
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
        running.activate()
        // Activation lands through the run loop: wait for it, briefly.
        let deadline = Date().addingTimeInterval(1)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        return "\(name) is not frontmost, so nothing was sent: another app would have had it."
    }
    return nil
}

/// The accessibility tree, indented, for `read`: role, label and frame, as ui.swift's
/// `dump` prints it.
func axDump(pid: pid_t, limit: Int = 20) -> String {
    let app = AXUIElementCreateApplication(pid)
    var lines: [String] = []
    axWalk(app, depth: 0, limit: limit) { element, depth in
        let text = axLabel(element)
        let box = axFrame(element).map { " @\(Int($0.origin.x)),\(Int($0.origin.y)) \(Int($0.width))x\(Int($0.height))" } ?? ""
        lines.append(String(repeating: "  ", count: depth) + axRole(element) + (text.isEmpty ? "" : " · " + text) + box)
        return true
    }
    return lines.joined(separator: "\n")
}

/// AXPress the innermost element whose label matches (substring, case-insensitive), the
/// same order ui.swift's `press` tries them in, walking up to 4 parents when the match
/// itself takes no press (a row's label is often a child of the button).
func axPress(pid: pid_t, label: String) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    let needle = label.lowercased()
    var matches: [AXUIElement] = []
    axWalk(app, depth: 0, limit: 30) { element, _ in
        if axLabel(element).lowercased().contains(needle) { matches.append(element) }
        return true
    }
    for element in matches.reversed() {
        if axPerformPress(element) { return true }
        var parent = axAttribute(element, kAXParentAttribute as String)
        var hops = 0
        while let current = parent, hops < 4 {
            // swiftlint:disable:next force_cast
            let up = current as! AXUIElement
            if axPerformPress(up) { return true }
            parent = axAttribute(up, kAXParentAttribute as String)
            hops += 1
        }
    }
    return false
}

private func axPerformPress(_ element: AXUIElement) -> Bool {
    var actions: CFArray?
    AXUIElementCopyActionNames(element, &actions)
    guard ((actions as? [String]) ?? []).contains(kAXPressAction as String) else { return false }
    return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
}
