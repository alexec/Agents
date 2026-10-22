#if DEBUG && targetEnvironment(simulator)
import AgentsKitCore
import Foundation
import UIKit

/// What the Remote's walk socket does (#1182), on the main thread, in this process: the
/// window draws itself into a PNG, reads its own accessibility tree, and presses and types
/// into its own elements. The same verbs and replies as the Mac's (#1172), less the ones a
/// phone has no use for (menus, window sizes, folding).
@MainActor
enum WalkCommands {
    static func run(_ line: Data) -> Data {
        let reply: [String: Any]
        do {
            guard let request = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let verb = request["cmd"] as? String else { throw WalkError("want {\"cmd\": …}") }
            reply = try perform(verb, request)
        } catch let error as WalkError {
            reply = ["ok": false, "error": error.text]
        } catch {
            reply = ["ok": false, "error": "\(error)"]
        }
        return (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data("{\"ok\":false}".utf8)
    }

    private static func perform(_ verb: String, _ request: [String: Any]) throws -> [String: Any] {
        switch verb {
        // Voice mode with no microphone and no sound (#2322).
        case "voice":
            return VoiceWalk.perform(request)
        case "ping":
            return ["ok": true, "pid": Int(getpid())]
        case "windows":
            return ["ok": true, "windows": windows().enumerated().map { describe($1, index: $0) }]
        case "views":
            // For when a shot or a press goes wrong.
            let window = try target(request)
            var lines: [String] = []
            func dump(_ view: UIView, _ level: Int) {
                guard level < (request["depth"] as? Int ?? 40) else { return }
                lines.append(String(repeating: "  ", count: level) + "\(type(of: view)) \(Int(view.frame.width))x\(Int(view.frame.height))"
                    + (view.isHidden ? " hidden" : "") + (view.isAccessibilityElement ? " ax" : ""))
                for sub in view.subviews { dump(sub, level + 1) }
            }
            dump(window, 0)
            return ["ok": true, "text": lines.joined(separator: "\n")]
        case "shot":
            let window = try target(request)
            guard let png = shot(window) else { throw WalkError("could not draw the window") }
            return ["ok": true, "png": png.base64EncodedString(), "width": Int(window.bounds.width),
                    "height": Int(window.bounds.height)]
        case "tree":
            let depth = request["depth"] as? Int ?? 30
            var lines: [String] = []
            for window in try scope(request) {
                lines.append("window · \(type(of: window)) \(Int(window.bounds.width))x\(Int(window.bounds.height))")
                visit(WalkAX(object: window), depth: 1, limit: depth) { element, level in
                    if element.shows { lines.append(String(repeating: "  ", count: level) + element.line(in: window)) }
                    return true
                }
            }
            return ["ok": true, "text": lines.joined(separator: "\n")]
        case "find":
            let found = try matches(request)
            return ["ok": !found.isEmpty, "matches": found.map { $0.element.line(in: $0.window) }]
        case "press", "select":
            // A list's row is pressed as a tap would: SwiftUI's List on iOS has no selection
            // of its own to set.
            return try act(request, verb: "pressed") { $0.press() }
        case "set":
            guard let value = request["value"] as? String else { throw WalkError("set wants a value") }
            guard let match = try matches(request).last else { throw WalkError("nothing matched \(request["text"] ?? "")") }
            guard let field = WalkAX.textInput(at: match.element, in: match.window) else {
                throw WalkError("\(match.element.line(in: match.window)) takes no text")
            }
            _ = field.becomeFirstResponder()
            if let input = field as? UITextInput, let range = input.textRange(from: input.beginningOfDocument, to: input.endOfDocument) {
                input.replace(range, withText: value)
            }
            return ["ok": true, "did": "set: \(match.element.line(in: match.window))"]
        case "key":
            // A key to the field being typed in: what the keyboard would send.
            guard let name = request["key"] as? String else { throw WalkError("key wants a key") }
            guard let input = firstResponder() as? UIKeyInput else { throw WalkError("nothing is being typed in") }
            switch name {
            case "return", "enter": input.insertText("\n")
            case "delete", "backspace": input.deleteBackward()
            case "escape", "dismiss": _ = (input as? UIResponder)?.resignFirstResponder()
            default: input.insertText(name)
            }
            return ["ok": true, "did": "key \(name)"]
        case "info":
            guard let match = try matches(request).last else { throw WalkError("nothing matched \(request["text"] ?? "")") }
            var lines: [String] = []
            var current: WalkAX? = match.element
            while let element = current, !(element.object is UIWindow), lines.count < 8 {
                lines.append("\(element.line(in: match.window)) [\(type(of: element.object))] traits: \(element.traitNames) actions: \(element.actionNames)")
                current = element.parent
            }
            return ["ok": true, "text": lines.joined(separator: "\n")]
        case "scroll":
            return try scroll(request)
        default:
            throw WalkError("unknown cmd \(verb)")
        }
    }

    // MARK: windows

    /// Every window of every scene, the key window first: an iPad may show more than one.
    static func windows() -> [UIWindow] {
        let all = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).filter { !$0.isHidden && $0.bounds.width > 0 }
        return all.filter(\.isKeyWindow) + all.filter { !$0.isKeyWindow }
    }

    private static func describe(_ window: UIWindow, index: Int) -> [String: Any] {
        ["index": index, "title": window.windowScene?.title ?? "", "frame": box(window.frame), "sheet": false,
         "key": window.isKeyWindow, "class": "\(type(of: window))"]
    }

    /// `window`: an index from `windows`; else the key window, the app's own.
    static func target(_ request: [String: Any]) throws -> UIWindow {
        let all = windows()
        if let index = request["window"] as? Int {
            guard all.indices.contains(index) else { throw WalkError("no window \(index)") }
            return all[index]
        }
        guard let window = all.first else { throw WalkError("no window open") }
        return window
    }

    private static func scope(_ request: [String: Any]) throws -> [UIWindow] {
        request["window"] == nil ? windows() : [try target(request)]
    }

    // MARK: drawing

    /// The window as it is drawn on the simulator's screen, which no one can see here.
    static func shot(_ window: UIWindow) -> Data? {
        let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { context in
            if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) {
                window.layer.render(in: context.cgContext)
            }
        }
        return image.pngData()
    }

    // MARK: the accessibility tree, read in process

    private static func visit(_ element: WalkAX, depth: Int, limit: Int, _ body: (WalkAX, Int) -> Bool) {
        for child in element.children {
            guard body(child, depth) else { return }
            if depth < limit { visit(child, depth: depth + 1, limit: limit, body) }
        }
    }

    struct Match { let element: WalkAX; let window: UIWindow }

    /// Every element whose label, or `#identifier`, holds `text`; `=text` is the whole label.
    static func matches(_ request: [String: Any]) throws -> [Match] {
        guard let raw = request["text"] as? String, !raw.isEmpty else { throw WalkError("want text to match") }
        let exact = raw.hasPrefix("=")
        let needle = (exact ? String(raw.dropFirst()) : raw).lowercased()
        var found: [Match] = []
        for window in try scope(request) {
            visit(WalkAX(object: window), depth: 1, limit: 60) { element, _ in
                let text = element.label.lowercased()
                let hit = needle.hasPrefix("#") ? element.identifier.lowercased() == needle.dropFirst()
                    : exact ? text == needle : text.contains(needle)
                if hit && element.shows { found.append(Match(element: element, window: window)) }
                return true
            }
        }
        return found
    }

    /// The innermost match that takes the action, or the nearest of its parents that does.
    private static func act(_ request: [String: Any], verb: String, hops: Int = 6,
                            _ action: (WalkAX) -> Bool) throws -> [String: Any] {
        let found = try matches(request)
        guard !found.isEmpty else { throw WalkError("nothing matched \(request["text"] ?? "")") }
        let ordered = (request["first"] as? Bool ?? false) ? found : found.reversed()
        for match in ordered {
            var current: WalkAX? = match.element
            var hop = 0
            while let element = current, !(element.object is UIWindow), hop <= hops {
                if action(element) {
                    return ["ok": true, "did": "\(verb): \(element.line(in: match.window))"]
                }
                current = element.parent
                hop += 1
            }
        }
        throw WalkError("nothing that could be \(verb) matched \(request["text"] ?? "")")
    }

    private static func firstResponder() -> UIResponder? {
        func search(_ view: UIView) -> UIResponder? {
            if view.isFirstResponder { return view }
            for sub in view.subviews { if let found = search(sub) { return found } }
            return nil
        }
        return windows().lazy.compactMap(search).first
    }

    // MARK: scrolling

    /// `text`: bring it into view, or scroll the view it is in; `to` top|bottom, `y`, `by`.
    /// With no text, the biggest scroll view on the window.
    private static func scroll(_ request: [String: Any]) throws -> [String: Any] {
        let window = try target(request)
        var match: Match?
        if request["text"] != nil {
            guard let found = try matches(request).last else { throw WalkError("nothing matched \(request["text"] ?? "")") }
            match = found
        }
        let scrollView: UIScrollView? = match.flatMap { WalkAX.enclosingScrollView(of: $0.element) } ?? biggestScrollView(in: window)
        guard let scrollView else { throw WalkError("no scroll view") }
        let inset = scrollView.adjustedContentInset
        let top = -inset.top
        let bottom = max(top, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
        var offset = scrollView.contentOffset
        if let to = request["to"] as? String {
            offset.y = to == "top" ? top : bottom
        } else if let y = request["y"] as? Double {
            offset.y = min(max(CGFloat(y), top), bottom)
        } else if let by = request["by"] as? Double {
            offset.y = min(max(offset.y + CGFloat(by), top), bottom)
        } else if let match {
            let box = WalkAX.local(match.element.frame, in: scrollView)
            dragged(scrollView) { scrollView.scrollRectToVisible(box, animated: false) }
            return ["ok": true, "did": "scrolled to \(match.element.line(in: match.window))", "y": Int(scrollView.contentOffset.y)]
        } else {
            throw WalkError("scroll wants text, to, y or by")
        }
        dragged(scrollView) { scrollView.setContentOffset(offset, animated: false) }
        return ["ok": true, "did": "scrolled \(type(of: scrollView))", "y": Int(scrollView.contentOffset.y)]
    }

    /// A move told to the scroll view's delegate as a drag that began and ended, as a finger
    /// makes one: SwiftUI's scroll phase then says a reader moved it, and a transcript that
    /// follows its foot lets go, as it does for a person.
    private static func dragged(_ scrollView: UIScrollView, _ move: () -> Void) {
        scrollView.delegate?.scrollViewWillBeginDragging?(scrollView)
        move()
        scrollView.delegate?.scrollViewDidScroll?(scrollView)
        var target = scrollView.contentOffset
        scrollView.delegate?.scrollViewWillEndDragging?(scrollView, withVelocity: .zero, targetContentOffset: &target)
        scrollView.delegate?.scrollViewDidEndDragging?(scrollView, willDecelerate: false)
    }

    /// Of the scroll views as big as half the window, the one with the most to scroll: a
    /// page's transcript, not the empty one SwiftUI wraps it in.
    private static func biggestScrollView(in window: UIWindow) -> UIScrollView? {
        var all: [UIScrollView] = []
        func search(_ view: UIView) {
            if let scroll = view as? UIScrollView, !scroll.isHidden, scroll.isScrollEnabled,
               scroll.bounds.width * scroll.bounds.height >= window.bounds.width * window.bounds.height / 2 {
                all.append(scroll)
            }
            for sub in view.subviews where !sub.isHidden { search(sub) }
        }
        search(window)
        return all.max { range($0) < range($1) }
    }

    private static func range(_ scroll: UIScrollView) -> CGFloat {
        scroll.contentSize.height + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom - scroll.bounds.height
    }

    static func box(_ rect: CGRect) -> [String: Int] {
        WalkBox(rect).dictionary
    }
}

struct WalkError: Error {
    let text: String
    init(_ text: String) { self.text = text }
}
#endif
