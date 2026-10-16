#if DEBUG
import AppKit
import Foundation

/// An element of the window's accessibility tree, read in process (#1172). Children go
/// through the entry point the AX server calls (`accessibilityAttributeValue:`), which alone
/// hands out a table's rows; the rest through the newer methods where the element has them,
/// as SwiftUI's own elements (`AccessibilityNode`) answer only those, and do not say they
/// conform to the protocol. Every method is called by its selector, typed, so a `BOOL`, a
/// rect or a `void` comes back as one.
@MainActor
struct WalkAX {
    let object: NSObject

    private typealias Object = @convention(c) (NSObject, Selector) -> Unmanaged<AnyObject>?
    private typealias Rect = @convention(c) (NSObject, Selector) -> NSRect
    private typealias Flag = @convention(c) (NSObject, Selector) -> Bool
    private typealias SetFlag = @convention(c) (NSObject, Selector, Bool) -> Void
    private typealias SetObject = @convention(c) (NSObject, Selector, AnyObject) -> Void
    private typealias Get = @convention(c) (NSObject, Selector, NSString) -> Unmanaged<AnyObject>?
    private typealias Set = @convention(c) (NSObject, Selector, AnyObject, NSString) -> Void
    private typealias Act = @convention(c) (NSObject, Selector, NSString) -> Void

    // MARK: calls by selector

    private func call(_ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return unsafeBitCast(object.method(for: selector), to: Object.self)(object, selector)?.takeUnretainedValue()
    }

    private func flag(_ name: String) -> Bool? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return unsafeBitCast(object.method(for: selector), to: Flag.self)(object, selector)
    }

    private func setFlag(_ name: String, _ value: Bool) -> Bool {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return false }
        unsafeBitCast(object.method(for: selector), to: SetFlag.self)(object, selector, value)
        return true
    }

    /// The attribute, as the AX server asks for it.
    func value(_ attribute: String) -> Any? {
        let selector = NSSelectorFromString("accessibilityAttributeValue:")
        guard object.responds(to: selector) else { return nil }
        return unsafeBitCast(object.method(for: selector), to: Get.self)(object, selector, attribute as NSString)?.takeUnretainedValue()
    }

    private func set(_ attribute: String, to new: AnyObject) {
        let selector = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        guard object.responds(to: selector) else { return }
        unsafeBitCast(object.method(for: selector), to: Set.self)(object, selector, new, attribute as NSString)
    }

    var actionNames: [String] {
        let custom = ((call("accessibilityCustomActions") as? [NSAccessibilityCustomAction]) ?? []).map { "custom:" + $0.name }
        return ((call("accessibilityActionNames") as? [String]) ?? []) + custom
    }

    var attributeNames: [String] { (call("accessibilityAttributeNames") as? [String]) ?? [] }

    // MARK: reading

    var children: [WalkAX] {
        // Either may come back empty where the other has them: a sheet's hosting view.
        let legacy = (value("AXChildren") as? [Any]) ?? []
        let all = legacy.isEmpty ? (call("accessibilityChildren") as? [Any]) ?? [] : legacy
        return all.compactMap { ($0 as? NSObject).map(WalkAX.init) }
    }

    var parent: WalkAX? { ((value("AXParent") ?? call("accessibilityParent")) as? NSObject).map(WalkAX.init) }
    var role: String { (call("accessibilityRole") as? String) ?? (value("AXRole") as? String) ?? "?\(object.className)" }
    var identifier: String { (call("accessibilityIdentifier") as? String) ?? (value("AXIdentifier") as? String) ?? "" }
    var isWindow: Bool { object is NSWindow || role == "AXWindow" || role == "AXApplication" }

    /// What a person would read on it, as `ui.swift` joins it, and an empty field's
    /// placeholder ("What do you want to do?"), which is how a walk finds the prompt.
    var label: String {
        let modern = ["accessibilityTitle", "accessibilityLabel", "accessibilityValue", "accessibilityHelp", "accessibilityPlaceholderValue"]
        let legacy = ["AXTitle", "AXDescription", "AXValue", "AXHelp", "AXPlaceholderValue"]
        return zip(modern, legacy).compactMap { (call($0) as? String) ?? (value($1) as? String) }
            .filter { !$0.isEmpty }.joined(separator: " | ")
    }

    /// On the screen, with the origin at the bottom left, as AppKit counts in process.
    var screenFrame: CGRect {
        if let position = (value("AXPosition") as? NSValue)?.pointValue, let size = (value("AXSize") as? NSValue)?.sizeValue {
            return CGRect(origin: position, size: size)
        }
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector) else { return .zero }
        return unsafeBitCast(object.method(for: selector), to: Rect.self)(object, selector)
    }

    /// In the window's own points from its top left: the same place as in its shot.
    func frame(in window: NSWindow) -> CGRect {
        let screen = screenFrame
        guard screen != .zero else { return .zero }
        let local = window.convertFromScreen(screen)
        return CGRect(x: local.minX, y: window.frame.height - local.maxY, width: local.width, height: local.height)
    }

    func line(in window: NSWindow) -> String {
        var line = role
        let text = label
        if !text.isEmpty { line += " · " + text }
        if !identifier.isEmpty { line += " #" + identifier }
        let box = frame(in: window)
        if box != .zero { line += " @\(Int(box.minX)),\(Int(box.minY)) \(Int(box.width))x\(Int(box.height))" }
        return line
    }

    // MARK: acting

    func press() -> Bool {
        if actionNames.contains("AXPress") {
            let selector = NSSelectorFromString("accessibilityPerformAction:")
            unsafeBitCast(object.method(for: selector), to: Act.self)(object, selector, "AXPress" as NSString)
            return true
        }
        return flag("accessibilityPerformPress") ?? false
    }

    /// A flag set (`AXSelected`, `AXDisclosing`) where the element has it. Not read back:
    /// SwiftUI takes it on its next update; `walk.py wait` sees the result.
    func set(_ attribute: String, _ new: Bool) -> Bool {
        if value(attribute) != nil {
            set(attribute, to: NSNumber(value: new))
            return true
        }
        return setFlag(attribute == "AXSelected" ? "setAccessibilitySelected:" : "setAccessibilityDisclosed:", new)
    }

    /// Text set as the element's value, and read back.
    func setValue(_ text: String) -> Bool {
        if value("AXValue") != nil {
            set("AXValue", to: text as NSString)
        } else {
            let selector = NSSelectorFromString("setAccessibilityValue:")
            guard object.responds(to: selector) else { return false }
            unsafeBitCast(object.method(for: selector), to: SetObject.self)(object, selector, text as NSString)
        }
        return label.contains(text)
    }
}
#endif
