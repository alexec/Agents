#if DEBUG
import AppKit
import Foundation

/// What the walk socket does (#1172), on the main thread, in this process: the window draws
/// itself into a PNG, reads its own accessibility tree, and presses, selects and types into
/// its own elements, as `ui.swift` does from outside through the AX server.
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
        case "ping":
            return ["ok": true, "pid": Int(getpid())]
        // For when a shot or a press goes wrong: the views, a view's layers.
        case "views":
            let window = try target(request)
            var lines: [String] = []
            func dump(_ view: NSView, _ level: Int) {
                guard level < (request["depth"] as? Int ?? 40) else { return }
                lines.append(String(repeating: "  ", count: level) + "\(view.className) \(Int(view.frame.width))x\(Int(view.frame.height)) ax:\((view.accessibilityChildren() ?? []).count)" + ((view as? NSTableView).map { " rows:\($0.numberOfRows) visible:\($0.rows(in: $0.visibleRect)) selected:\(Array($0.selectedRowIndexes))" } ?? ""))
                for sub in view.subviews { dump(sub, level + 1) }
            }
            if let frameView = window.contentView?.superview { dump(frameView, 0) }
            return ["ok": true, "text": lines.joined(separator: "\n")]
        case "layers":
            let window = try target(request)
            guard let view = WalkShot.pick(request["view"] as? String ?? "NSThemeFrame", in: window),
                  let layer = view.layer else { throw WalkError("no such view, or no layer") }
            var lines: [String] = []
            func dump(_ layer: CALayer, _ level: Int) {
                guard level < (request["depth"] as? Int ?? 8) else { return }
                let delegate = (layer.delegate as? NSObject).map { " ← \($0.className)" } ?? ""
                lines.append(String(repeating: "  ", count: level) + "\(layer.className) \(Int(layer.bounds.width))x\(Int(layer.bounds.height))"
                    + (layer.mask != nil ? " mask" : "") + (layer.isHidden ? " hidden" : "") + " op:\(layer.opacity)" + delegate)
                for sub in layer.sublayers ?? [] { dump(sub, level + 1) }
            }
            dump(layer, 0)
            return ["ok": true, "text": lines.joined(separator: "\n")]
        case "windows":
            return ["ok": true, "windows": windows().enumerated().map { describe($1, index: $0) }]
        case "shot":
            let window = try target(request)
            let drawn = (request["view"] as? String).map { WalkShot.png(ofView: $0, in: window) }
                ?? WalkShot.png(of: window)
            guard let png = drawn else { throw WalkError("could not draw the window") }
            return ["ok": true, "png": png.base64EncodedString(), "width": Int(window.frame.width),
                    "height": Int(window.frame.height)]
        case "tree":
            let depth = request["depth"] as? Int ?? 30
            var lines: [String] = []
            for window in try scope(request) {
                WalkShot.prepare(window)
                lines.append("window · \(window.title)")
                visit(WalkAX(object: window), depth: 1, limit: depth) { element, level in
                    lines.append(String(repeating: "  ", count: level) + element.line(in: window))
                    return true
                }
            }
            return ["ok": true, "text": lines.joined(separator: "\n")]
        case "find":
            let found = try matches(request)
            return ["ok": !found.isEmpty, "matches": found.map { $0.element.line(in: $0.window) }]
        case "press":
            return try act(request, verb: "pressed") { $0.press() }
        case "select":
            // A row only: a list's selection is set on its row, as a click would.
            return try act(request, verb: "selected") { element in
                guard element.role == "AXRow" else { return false }
                // Through its table, the way a click and an arrow key select (AppKit's own,
                // not API): SwiftUI's List puts back an `AXSelected` or a
                // `selectRowIndexes` it was not told of as the person's.
                typealias UserSelect = @convention(c) (NSObject, Selector, Int) -> Void
                let user = NSSelectorFromString("_userSelectSingleRow:")
                guard let (table, row) = tableRow(element), table.responds(to: user) else {
                    return element.set("AXSelected", true)
                }
                unsafeBitCast(table.method(for: user), to: UserSelect.self)(table, user, row)
                return true
            }
        case "unfold", "fold":
            return try act(request, verb: verb == "unfold" ? "unfolded" : "folded") { element in
                guard element.role == "AXRow" else { return false }
                // An outline's row the way its disclosure button folds it (AppKit's own, not
                // API): SwiftUI puts back an `expandItem` or an `AXDisclosing` it was not
                // told of as the person's.
                typealias UserExpand = @convention(c) (NSObject, Selector, AnyObject, Bool, Bool) -> Void
                let user = NSSelectorFromString("_doUserExpandOrCollapseOfItem:isExpand:optionKeyWasDown:")
                if let (table, row) = tableRow(element), let outline = table as? NSOutlineView, outline.responds(to: user),
                   let item = outline.item(atRow: row) as AnyObject? {
                    unsafeBitCast(outline.method(for: user), to: UserExpand.self)(outline, user, item, verb == "unfold", false)
                    return true
                }
                return element.set("AXDisclosing", verb == "unfold")
            }
        case "set":
            guard let value = request["value"] as? String else { throw WalkError("set wants a value") }
            guard let match = try matches(request).last else { throw WalkError("nothing matched \(request["text"] ?? "")") }
            guard WalkText.set(match.element, in: match.window, to: value) else {
                throw WalkError("\(match.element.line(in: match.window)) takes no text")
            }
            return ["ok": true, "did": "set: \(match.element.line(in: match.window))"]
        case "info":
            // The innermost match and the elements above it: what each is and takes.
            guard let match = try matches(request).last else { throw WalkError("nothing matched \(request["text"] ?? "")") }
            var lines: [String] = []
            var current: WalkAX? = match.element
            while let element = current, !element.isWindow, lines.count < 8 {
                lines.append("\(element.line(in: match.window)) [\(element.object.className)] actions: \(element.actionNames) attributes: \(element.attributeNames)")
                current = element.parent
            }
            return ["ok": true, "text": lines.joined(separator: "\n")]
        case "click":
            let count = request["count"] as? Int ?? 1
            if let x = request["x"] as? Double, let y = request["y"] as? Double {
                return ["ok": true, "did": try WalkEvents.click(try target(request), at: CGPoint(x: x, y: y), count: count)]
            }
            // The innermost match's middle: what a pointer over its label would hit.
            guard let match = try matches(request).last else { throw WalkError("nothing matched \(request["text"] ?? "")") }
            let box = match.element.frame(in: match.window)
            guard box != .zero else { throw WalkError("\(match.element.line(in: match.window)) has no frame") }
            return ["ok": true, "did": try WalkEvents.click(match.window, at: CGPoint(x: box.midX, y: box.midY), count: count)]
        case "key":
            guard let name = request["key"] as? String else { throw WalkError("key wants a key") }
            let window = try target(request)
            return ["ok": true, "did": try WalkEvents.key(window.attachedSheet ?? window, name, modifiers: request["modifiers"] as? [String] ?? [])]
        case "scroll":
            return try WalkScroll.run(request, matches: { try matches($0) })
        case "size":
            let window = try target(request)
            guard let width = request["width"] as? Double, let height = request["height"] as? Double else {
                throw WalkError("size wants width and height")
            }
            var frame = window.frame
            frame.origin.y += frame.height - height
            frame.size = CGSize(width: width, height: height)
            window.setFrame(frame, display: true)
            return ["ok": true, "frame": box(window.frame)]
        case "menu":
            guard let path = request["path"] as? [String], !path.isEmpty else { throw WalkError("menu wants a path") }
            return try menu(path)
        default:
            throw WalkError("unknown cmd \(verb)")
        }
    }

    // MARK: windows

    /// Front to back, visible ones only: what a person would see, sheets included.
    static func windows() -> [NSWindow] {
        NSApp.orderedWindows.filter { $0.isVisible && $0.className != "NSStatusBarWindow" }
    }

    private static func describe(_ window: NSWindow, index: Int) -> [String: Any] {
        ["index": index, "title": window.title, "frame": box(window.frame), "sheet": window.isSheet,
         "key": window.isKeyWindow, "class": window.className, "number": window.windowNumber]
    }

    /// `window`: an index from `windows`, or words of its title; else the biggest window that
    /// is not a sheet, the scratch window itself.
    static func target(_ request: [String: Any]) throws -> NSWindow {
        let all = windows()
        if let index = request["window"] as? Int {
            guard all.indices.contains(index) else { throw WalkError("no window \(index)") }
            return all[index]
        }
        if let title = request["window"] as? String {
            guard let window = all.first(where: { $0.title.localizedCaseInsensitiveContains(title) }) else {
                throw WalkError("no window titled \(title)")
            }
            return window
        }
        guard let window = all.filter({ !$0.isSheet }).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            throw WalkError("no window open")
        }
        return window
    }

    /// Where a search looks: the window named, with its sheets first; else every window.
    private static func scope(_ request: [String: Any]) throws -> [NSWindow] {
        guard request["window"] != nil else { return windows() }
        let window = try target(request)
        return [window.attachedSheet].compactMap { $0 } + window.childWindows.orEmpty + [window]
    }

    // MARK: the accessibility tree, read in process

    private static func visit(_ element: WalkAX, depth: Int, limit: Int, _ body: (WalkAX, Int) -> Bool) {
        for child in element.children {
            guard body(child, depth) else { return }
            if depth < limit { visit(child, depth: depth + 1, limit: limit, body) }
        }
    }

    struct Match { let element: WalkAX; let window: NSWindow }

    /// Every element whose label, or `#identifier`, holds `text`; `=text` is the whole label.
    static func matches(_ request: [String: Any]) throws -> [Match] {
        guard let raw = request["text"] as? String, !raw.isEmpty else { throw WalkError("want text to match") }
        let exact = raw.hasPrefix("=")
        let needle = (exact ? String(raw.dropFirst()) : raw).lowercased()
        var found: [Match] = []
        for window in try scope(request) {
            WalkShot.prepare(window)
            visit(WalkAX(object: window), depth: 1, limit: 40) { element, _ in
                let text = element.label.lowercased()
                let hit = needle.hasPrefix("#") ? element.identifier.lowercased() == needle.dropFirst()
                    : exact ? text == needle : text.contains(needle)
                if hit { found.append(Match(element: element, window: window)) }
                return true
            }
        }
        return found
    }

    /// The innermost match that takes the action, or the nearest of its parents that does:
    /// a row's label is often a child of the button that does something.
    private static func act(_ request: [String: Any], verb: String, hops: Int = 6,
                            _ action: (WalkAX) -> Bool) throws -> [String: Any] {
        let found = try matches(request)
        guard !found.isEmpty else { throw WalkError("nothing matched \(request["text"] ?? "")") }
        let ordered = (request["first"] as? Bool ?? false) ? found : found.reversed()
        for match in ordered {
            var current: WalkAX? = match.element
            var hop = 0
            while let element = current, !element.isWindow, hop <= hops {
                if action(element) {
                    return ["ok": true, "did": "\(verb): \(element.line(in: match.window))"]
                }
                current = element.parent
                hop += 1
            }
        }
        throw WalkError("nothing that could be \(verb) matched \(request["text"] ?? "")")
    }

    /// The table a row element is in, and its index: the element is AppKit's stand-in for
    /// the row (`NSOutlineRow`), or the row view.
    private static func tableRow(_ element: WalkAX) -> (NSTableView, Int)? {
        guard let table = WalkText.view(of: element).flatMap({ $0 as? NSTableView ?? $0.superview as? NSTableView }) else { return nil }
        if let rowView = element.object as? NSTableRowView {
            let row = table.row(for: rowView)
            return row >= 0 ? (table, row) : nil
        }
        guard let index = (element.value("AXIndex") as? NSNumber)?.intValue, index >= 0, index < table.numberOfRows else { return nil }
        return (table, index)
    }

    // MARK: the menu bar, in place of a keyboard shortcut

    private static func menu(_ path: [String]) throws -> [String: Any] {
        guard var menu = NSApp.mainMenu else { throw WalkError("no menu bar") }
        for (at, title) in path.enumerated() {
            menu.update()
            guard let index = menu.items.firstIndex(where: { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame })
                ?? menu.items.firstIndex(where: { $0.title.localizedCaseInsensitiveContains(title) }) else {
                throw WalkError("no menu item \(title); there are \(menu.items.map(\.title).filter { !$0.isEmpty })")
            }
            let item = menu.items[index]
            if at == path.count - 1, let items = item.submenu?.items {
                // A menu, not an item: say what is in it.
                item.submenu?.update()
                return ["ok": true, "did": items.filter { !$0.isSeparatorItem }
                    .map { $0.title + ($0.isEnabled ? "" : " (off)") }.joined(separator: "\n")]
            }
            if at == path.count - 1 {
                guard item.isEnabled else { throw WalkError("\(item.title) is turned off") }
                menu.performActionForItem(at: index)
                return ["ok": true, "did": "chose \(path.joined(separator: " ▸ "))"]
            }
            guard let next = item.submenu else { throw WalkError("\(item.title) has no menu") }
            menu = next
        }
        throw WalkError("empty path")
    }

    static func box(_ rect: CGRect) -> [String: Int] {
        ["x": Int(rect.minX), "y": Int(rect.minY), "width": Int(rect.width), "height": Int(rect.height)]
    }
}

struct WalkError: Error {
    let text: String
    init(_ text: String) { self.text = text }
}

private extension Optional where Wrapped == [NSWindow] {
    var orEmpty: [NSWindow] { self ?? [] }
}
#endif
