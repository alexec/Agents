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

/// One element's role, label, frame and children, read in a single AX call (#3109): seven
/// separate attribute reads per node made a big app's tree (a browser, Xcode) take tens of
/// thousands of IPC round trips.
struct AXNode {
    var role = "?"
    var label = ""
    var frame: CGRect?
    var children: [AXUIElement] = []
}

func axNode(_ element: AXUIElement) -> AXNode {
    var node = AXNode()
    // Made here, not as a global: a global CFArray is not Sendable under strict concurrency.
    let attributes = [
        kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
        kAXHelpAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute,
    ] as CFArray
    var values: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(element, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
          let list = values as? [AnyObject], list.count == 8 else { return node }
    // A missing attribute comes back as an AXValue of type .axError, which none of these
    // casts take.
    if let role = list[0] as? String { node.role = role }
    node.label = list[1...4].compactMap { $0 as? String }.filter { !$0.isEmpty }.joined(separator: " | ")
    var point = CGPoint.zero, size = CGSize.zero
    if CFGetTypeID(list[5]) == AXValueGetTypeID(), CFGetTypeID(list[6]) == AXValueGetTypeID(),
       // swiftlint:disable:next force_cast
       AXValueGetValue(list[5] as! AXValue, .cgPoint, &point),
       // swiftlint:disable:next force_cast
       AXValueGetValue(list[6] as! AXValue, .cgSize, &size) {
        node.frame = CGRect(origin: point, size: size)
    }
    node.children = (list[7] as? [AXUIElement]) ?? []
    return node
}

/// The app's root element. Every AX call from this process first gets a short timeout
/// (set on the system-wide element, so it holds for each element of the walk too): one
/// call against a hung app, or one paused in the debugger, gives up in seconds, not the
/// system's default (#3109).
func axApplication(_ pid: pid_t) -> AXUIElement {
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 2)
    return AXUIElementCreateApplication(pid)
}

/// Walks depth-first to `limit` deep and at most `budget` nodes, until `visit` says stop,
/// and says whether it stopped before the end, for the budget or for `visit` (#3109).
@discardableResult
func axWalk(_ element: AXUIElement, depth: Int, limit: Int, budget: inout Int,
            visit: (AXUIElement, AXNode, Int) -> Bool) -> Bool {
    if budget <= 0 { return true }
    budget -= 1
    let node = axNode(element)
    if !visit(element, node, depth) { return true }
    if depth >= limit { return false }
    for child in node.children where axWalk(child, depth: depth + 1, limit: limit, budget: &budget, visit: visit) {
        return true
    }
    return false
}

/// Whether this process (Agents Host, by #3004's research R1) has the Accessibility
/// permission, triggering macOS's own grant prompt on first use if not (FR-005).
///
/// The option's own key, not `kAXTrustedCheckOptionPrompt` (a non-`Sendable` `CFStringRef`
/// global that fails this build's strict concurrency check): its value is documented and
/// stable, `"AXTrustedCheckOptionPrompt"`.
func axIsTrusted() -> Bool {
    AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
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
///
/// At most `maxNodes` nodes and about `maxBytes` of text (#3109): a browser's or Xcode's
/// tree has tens of thousands, and the whole string goes into the agent's context. A dump
/// cut short ends with a line that says so.
func axDump(pid: pid_t, limit: Int = 20, maxNodes: Int = 2000, maxBytes: Int = 128 * 1024) -> String {
    var lines: [String] = []
    var bytes = 0
    var budget = maxNodes
    let trimmed = axWalk(axApplication(pid), depth: 0, limit: limit, budget: &budget) { _, node, depth in
        if bytes >= maxBytes { return false }
        let box = node.frame.map { " @\(Int($0.origin.x)),\(Int($0.origin.y)) \(Int($0.width))x\(Int($0.height))" } ?? ""
        var line = String(repeating: "  ", count: depth) + node.role + (node.label.isEmpty ? "" : " · " + node.label) + box
        if line.utf8.count > 1024 { line = String(line.prefix(1000)) + "…" } // a text area's whole value
        lines.append(line)
        bytes += line.utf8.count + 1
        return true
    }
    if trimmed {
        lines.append("… trimmed at \(lines.count) elements: click by label still finds the rest, or read a smaller app.")
    }
    return lines.joined(separator: "\n")
}

/// AXPress the innermost element whose label matches (substring, case-insensitive), the
/// same order ui.swift's `press` tries them in, walking up to 4 parents when the match
/// itself takes no press (a row's label is often a child of the button).
func axPress(pid: pid_t, label: String) -> Bool {
    let needle = label.lowercased()
    var matches: [AXUIElement] = []
    var budget = 20000 // a bound on the walk, as axDump's (#3109), but wider: it returns no text.
    axWalk(axApplication(pid), depth: 0, limit: 30, budget: &budget) { element, node, _ in
        if node.label.lowercased().contains(needle) { matches.append(element) }
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
