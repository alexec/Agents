#if DEBUG
import AppKit
import Foundation

/// Text typed into a field in process (#1172): through the text view or the field editor,
/// as a keyboard would, so the SwiftUI binding behind it hears it. An AX value set does
/// not move a SwiftUI binding.
@MainActor
enum WalkText {
    static func set(_ element: WalkAX, in window: NSWindow, to text: String) -> Bool {
        switch field(of: element, in: window) {
        case let textView as NSTextView:
            textView.window?.makeFirstResponder(textView)
            textView.selectAll(nil)
            textView.insertText(text, replacementRange: textView.selectedRange())
            return true
        case let field as NSTextField:
            // The window's one field editor goes to the field that is first responder: it
            // must be this one's before anything is typed into it.
            guard field.window?.makeFirstResponder(field) == true,
                  let editor = field.currentEditor() as? NSTextView, editor.delegate === field else {
                field.stringValue = text
                return true
            }
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: editor.selectedRange())
            return true
        default:
            return element.setValue(text)
        }
    }

    /// The text view or editable field the element is, or the smallest one under its
    /// middle: SwiftUI's element for a field is not the field's view. Never a field editor,
    /// which belongs to whichever field has the keyboard.
    private static func field(of element: WalkAX, in window: NSWindow) -> NSView? {
        if let view = element.object as? NSTextView, !view.isFieldEditor { return view }
        if let view = element.object as? NSTextField, view.isEditable { return view }
        // SwiftUI's element for a field can be its cell (#3237): the field is the cell's view.
        if let view = (element.object as? NSCell)?.controlView as? NSTextField, view.isEditable { return view }
        // A sheet's field is found in the sheet, which is its own window over this one (#3237).
        for window in [window.attachedSheet, window].compactMap({ $0 }) {
            if let view = field(at: element, in: window) { return view }
        }
        return nil
    }

    private static func field(at element: WalkAX, in window: NSWindow) -> NSView? {
        let box = element.frame(in: window)
        guard box != .zero, let root = window.contentView?.superview else { return nil }
        let middle = CGPoint(x: box.midX, y: window.frame.height - box.midY)
        return root.subviews(of: NSView.self)
            .filter { ($0 as? NSTextView).map { !$0.isFieldEditor && $0.isEditable } ?? ($0 as? NSTextField)?.isEditable ?? false }
            .filter { !$0.isHiddenOrHasHiddenAncestor && $0.convert($0.bounds, to: root).contains(middle) }
            .min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    /// The view an element is, or the nearest view it sits in.
    static func view(of element: WalkAX) -> NSView? {
        var current: WalkAX? = element
        var hops = 0
        while let now = current, hops < 12 {
            if let view = now.object as? NSView { return view }
            current = now.parent
            hops += 1
        }
        return nil
    }
}

extension NSView {
    /// Every view of a kind under this one, nearest first.
    func subviews<T: NSView>(of kind: T.Type) -> [T] {
        var found: [T] = []
        var queue = subviews
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let match = next as? T { found.append(match) }
            queue += next.subviews
        }
        return found
    }
}
#endif
