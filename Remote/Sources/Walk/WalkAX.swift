#if DEBUG && targetEnvironment(simulator)
import UIKit

/// An element of the Remote's accessibility tree, read in process (#1182): a view, or one of
/// the elements a view hands out in its place (SwiftUI's nodes), through UIKit's informal
/// accessibility protocol, as VoiceOver reads it.
@MainActor
struct WalkAX {
    let object: NSObject

    // MARK: reading

    /// The elements it hands out where it has them, else its subviews.
    var children: [WalkAX] {
        if let elements = object.accessibilityElements, !elements.isEmpty {
            return elements.compactMap { ($0 as? NSObject).map(WalkAX.init) }
        }
        let count = object.accessibilityElementCount()
        if count > 0, count != NSNotFound {
            return (0..<count).compactMap { (object.accessibilityElement(at: $0) as? NSObject).map(WalkAX.init) }
        }
        guard let view = object as? UIView else { return [] }
        return view.subviews.filter { !$0.isHidden && $0.alpha > 0.01 }.map(WalkAX.init)
    }

    var parent: WalkAX? {
        if let view = object as? UIView { return view.superview.map(WalkAX.init) }
        // SwiftUI's nodes answer it without being `UIAccessibilityElement`s.
        let container = NSSelectorFromString("accessibilityContainer")
        guard object.responds(to: container) else { return nil }
        return (object.perform(container)?.takeUnretainedValue() as? NSObject).map(WalkAX.init)
    }

    var identifier: String { (object as? UIAccessibilityIdentification)?.accessibilityIdentifier ?? "" }

    /// What a person would hear on it: the label, the value, and an empty field's placeholder,
    /// which is how a walk finds the prompt.
    var label: String {
        var parts: [String] = []
        if let label = object.accessibilityLabel, !label.isEmpty { parts.append(label) }
        if let value = object.accessibilityValue, !value.isEmpty, !parts.contains(value) { parts.append(value) }
        if let field = object as? UITextField, parts.isEmpty, let placeholder = field.placeholder { parts.append(placeholder) }
        if let label = object as? UILabel, parts.isEmpty, let text = label.text { parts.append(text) }
        return parts.joined(separator: " ")
    }

    /// Worth a line: it says something, or VoiceOver would stop on it.
    var shows: Bool { !label.isEmpty || !identifier.isEmpty || isElement }

    var isElement: Bool { object.isAccessibilityElement }

    /// On the screen, in screen points.
    var frame: CGRect {
        if let view = object as? UIView, !view.isAccessibilityElement || object.accessibilityFrame == .zero {
            return view.convert(view.bounds, to: nil)
        }
        return object.accessibilityFrame
    }

    /// A frame on the screen, in a view's own points: `.null` where an element has none.
    static func local(_ rect: CGRect, in view: UIView) -> CGRect {
        guard let screen = view.window?.screen else { return rect }
        return view.convert(rect, from: screen.coordinateSpace)
    }

    var traitNames: [String] {
        let traits = object.accessibilityTraits
        let named: [(UIAccessibilityTraits, String)] = [
            (.button, "button"), (.link, "link"), (.header, "header"), (.selected, "selected"),
            (.staticText, "text"), (.image, "image"), (.searchField, "search"), (.adjustable, "adjustable"),
            (.notEnabled, "off"), (.tabBar, "tabbar"),
        ]
        return named.filter { traits.contains($0.0) }.map(\.1)
    }

    var actionNames: [String] {
        (object.accessibilityCustomActions ?? []).map(\.name)
    }

    func line(in window: UIWindow) -> String {
        let box = WalkAX.local(frame, in: window).finite
        let kind = object is UIView ? "\(type(of: object))" : (traitNames.first ?? "element")
        let id = identifier.isEmpty ? "" : " #\(identifier)"
        let traits = traitNames.isEmpty ? "" : " [\(traitNames.joined(separator: ","))]"
        return "\(kind) \"\(label)\"\(id)\(traits) @\(Int(box.minX)),\(Int(box.minY)) \(Int(box.width))x\(Int(box.height))"
    }

    // MARK: acting

    /// A tap, as VoiceOver's double tap makes one: the element's own activation, else a
    /// control's action, else a collection's row selected through its delegate.
    func press() -> Bool {
        if object.accessibilityTraits.contains(.notEnabled) { return false }
        if let control = object as? UIControl, control.isEnabled {
            control.sendActions(for: .primaryActionTriggered)
            control.sendActions(for: .touchUpInside)
            return true
        }
        if let cell = object as? UICollectionViewCell, let list = cell.superview as? UICollectionView,
           let path = list.indexPath(for: cell) {
            list.selectItem(at: path, animated: false, scrollPosition: [])
            list.delegate?.collectionView?(list, didSelectItemAt: path)
            return true
        }
        if let cell = object as? UITableViewCell, let table = cell.superview as? UITableView,
           let path = table.indexPath(for: cell) {
            table.selectRow(at: path, animated: false, scrollPosition: .none)
            table.delegate?.tableView?(table, didSelectRowAt: path)
            return true
        }
        guard isElement || object.accessibilityTraits.contains(.button) else { return false }
        if object.accessibilityActivate() { return true }
        // An element that does not activate (the navigation bar's back button): the control
        // drawn under its middle, as a tap there would reach.
        guard let window = WalkCommands.windows().first else { return false }
        let box = WalkAX.local(frame, in: window).finite
        var hit = box == .zero ? nil : window.hitTest(CGPoint(x: box.midX, y: box.midY), with: nil)
        while let view = hit {
            if let control = view as? UIControl, control.isEnabled {
                control.sendActions(for: .primaryActionTriggered)
                control.sendActions(for: .touchUpInside)
                return true
            }
            hit = view.superview
        }
        return false
    }

    /// The text field or text view an element is, holds, or is drawn over.
    static func textInput(at element: WalkAX, in window: UIWindow) -> UIResponder? {
        func search(_ view: UIView) -> UIResponder? {
            if view is UITextField || view is UITextView { return view }
            for sub in view.subviews { if let found = search(sub) { return found } }
            return nil
        }
        if let view = element.object as? UIView, let found = search(view) { return found }
        let box = WalkAX.local(element.frame, in: window)
        var hit = window.hitTest(CGPoint(x: box.midX, y: box.midY), with: nil)
        while let view = hit {
            if let found = search(view) { return found }
            hit = view.superview
        }
        return nil
    }

    /// The scroll view an element is in: its own view's, or the one under its middle.
    static func enclosingScrollView(of element: WalkAX) -> UIScrollView? {
        var view: UIView? = element.object as? UIView
        if view == nil, let window = WalkCommands.windows().first {
            let box = WalkAX.local(element.frame, in: window)
            view = window.hitTest(CGPoint(x: box.midX, y: box.midY), with: nil)
        }
        while let current = view {
            if let scroll = current as? UIScrollView, scroll.isScrollEnabled { return scroll }
            view = current.superview
        }
        return nil
    }
}
extension CGRect {
    /// Zero for a null or infinite frame (`CGRect.infinite` is huge but finite), which an
    /// element with no place on the screen has, and which would trap as an `Int`.
    var finite: CGRect {
        [minX, minY, width, height].allSatisfy { $0.isFinite && abs($0) < 1_000_000 } ? self : .zero
    }
}
#endif
