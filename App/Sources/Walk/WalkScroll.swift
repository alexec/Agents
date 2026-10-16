#if DEBUG
import AppKit
import Foundation

/// Scrolling in process (#1172): an element brought into view, or a scroll view moved to
/// the top, the bottom or an offset. No scroll events, so no phases: a gesture's feel
/// stays a walk for the screen.
@MainActor
enum WalkScroll {
    static func run(_ request: [String: Any],
                    matches: ([String: Any]) throws -> [WalkCommands.Match]) throws -> [String: Any] {
        let window = try WalkCommands.target(request)
        let to = request["to"] as? String
        let y = request["y"] as? Double
        let by = request["by"] as? Double
        // An element, and nothing else asked: bring it into view.
        if request["text"] != nil, to == nil, y == nil, by == nil {
            guard let match = try matches(request).last else { throw WalkError("nothing matched \(request["text"] ?? "")") }
            guard let view = WalkText.view(of: match.element) else { throw WalkError("no view to scroll to") }
            let local = view.convert(window.convertFromScreen(match.element.screenFrame), from: nil)
            view.scrollToVisible(local)
            return ["ok": true, "did": "scrolled to \(match.element.label)"]
        }
        // Which scroll view: the one an element sits in, else the biggest in the window.
        var scroller: NSScrollView?
        if request["text"] != nil, let match = try matches(request).last {
            scroller = WalkText.view(of: match.element)?.enclosingScrollView
        }
        if scroller == nil, let content = window.contentView {
            scroller = content.subviews(of: NSScrollView.self)
                .max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })
        }
        guard let scroller, let document = scroller.documentView else { throw WalkError("no scroll view") }
        let clip = scroller.contentView
        let most = max(0, document.frame.height - clip.bounds.height)
        var offset = clip.bounds.origin.y
        // An offset counts from the top, whichever way the document is drawn.
        let fromTop = { (top: CGFloat) in document.isFlipped ? top : most - top }
        switch to {
        case "top": offset = fromTop(0)
        case "bottom": offset = fromTop(most)
        default:
            if let y { offset = fromTop(CGFloat(y)) }
            if let by { offset += document.isFlipped ? CGFloat(by) : -CGFloat(by) }
        }
        clip.scroll(to: CGPoint(x: clip.bounds.origin.x, y: min(max(0, offset), most)))
        scroller.reflectScrolledClipView(clip)
        let top = document.isFlipped ? clip.bounds.origin.y : most - clip.bounds.origin.y
        return ["ok": true, "did": "scrolled", "top": Int(top), "height": Int(document.frame.height)]
    }
}
#endif
