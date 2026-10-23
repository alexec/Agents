#if DEBUG
import AgentsKitCore
import AppKit
import Foundation

/// What the walk socket does (#1172), on the main thread, in this process: the window draws
/// itself into a PNG, reads its own accessibility tree, and presses, selects and types into
/// its own elements, as `ui.swift` does from outside through the AX server.
@MainActor
enum WalkCommands {
    /// What to send back, made off the main thread once this returns: a shot's PNG is
    /// encoded there.
    static func run(_ line: Data) -> @Sendable () -> Data {
        var reply: [String: Any]
        do {
            guard let request = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let verb = request["cmd"] as? String else { throw WalkError("want {\"cmd\": …}") }
            reply = try perform(verb, request)
        } catch let error as WalkError {
            reply = ["ok": false, "error": error.text]
        } catch {
            reply = ["ok": false, "error": "\(error)"]
        }
        let drawn = reply.removeValue(forKey: "picture") as? WalkShot.Drawn
        let head = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data("{\"ok\":false}".utf8)
        guard let drawn else { return { head } }
        return {
            guard let png = drawn.png else { return Data("{\"ok\":false,\"error\":\"could not encode the window\"}".utf8) }
            return Data("{\"png\":\"".utf8) + png.base64EncodedData() + Data("\",".utf8) + head.dropFirst()
        }
    }

    private static func perform(_ verb: String, _ request: [String: Any]) throws -> [String: Any] {
        switch verb {
        // Voice mode with no microphone and no sound (#2322).
        case "voice":
            return VoiceWalk.perform(request)
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
                    + (layer.mask != nil ? " mask" : "") + (layer.isHidden ? " hidden" : "") + " op:\(layer.opacity)"
                    + (layer.isGeometryFlipped ? " geometryFlipped" : "") + (layer.contentsAreFlipped() ? " contentsFlipped" : "") + (layer.contents == nil ? " noContents" : "")
                    + (CATransform3DIsIdentity(layer.transform) ? "" : " transform") + delegate)
                for sub in layer.sublayers ?? [] { dump(sub, level + 1) }
            }
            dump(layer, 0)
            return ["ok": true, "text": lines.joined(separator: "\n")]
        case "windows":
            // `all`: the minimised and the hidden too, with their scene identifiers (#1454).
            let listed = request["all"] as? Bool == true ? NSApp.windows.filter { $0.className != "NSStatusBarWindow" } : windows()
            return ["ok": true, "windows": listed.enumerated().map { describe($1, index: $0) }]
        // A window minimised, closed or sent behind the others, as its buttons and a click
        // on another window would (#1454).
        case "minimize":
            let window = try anyWindow(request)
            window.miniaturize(nil)
            return ["ok": true, "did": "minimised \(window.title)"]
        case "close":
            let window = try anyWindow(request)
            window.performClose(nil)
            return ["ok": true, "did": "closed \(window.title)"]
        case "back":
            let window = try anyWindow(request)
            window.orderBack(nil)
            return ["ok": true, "did": "sent \(window.title) behind"]
        case "shot":
            let window = try target(request)
            let drawn = (request["view"] as? String).map { WalkShot.picture(ofView: $0, in: window) }
                ?? WalkShot.picture(of: window, shadows: request["shadows"] as? Bool ?? true,
                                    scale: (request["scale"] as? Double).map { CGFloat($0) })
            guard let drawn else { throw WalkError("could not draw the window") }
            return ["ok": true, "picture": drawn, "width": Int(window.frame.width),
                    "height": Int(window.frame.height)]
        // What the app gives the Dock tile (#1317): its icon as the Dock draws it, and the
        // badge. On a locked screen there is no Dock to take a picture of.
        case "dock":
            let size = request["size"] as? Int ?? 256
            guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { throw WalkError("could not make a canvas") }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
            NSApp.applicationIconImage.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
            NSGraphicsContext.restoreGraphicsState()
            return ["ok": true, "picture": WalkShot.Drawn(canvas: canvas), "badge": NSApp.dockTile.badgeLabel ?? ""]
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
            if let x = request["x"] as? Double, let y = request["y"] as? Double {
                return try pressAt(try target(request), CGPoint(x: x, y: y))
            }
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
                // The list has the keyboard after it, as after a click: ⇧↓ then picks more (#1664).
                table.window?.makeFirstResponder(table)
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
            // `x` and `y`: its top left, in points from the main screen's top left, as AX
            // has it. A shot is drawn at the scale of the screen the window is on (#1078).
            if let x = request["x"] as? Double, let y = request["y"] as? Double,
               let main = NSScreen.screens.first {
                frame.origin = CGPoint(x: x, y: main.frame.maxY - y - height)
            }
            window.setFrame(frame, display: true)
            return ["ok": true, "frame": box(window.frame), "scale": window.backingScaleFactor]
        case "menu":
            guard let path = request["path"] as? [String], !path.isEmpty else { throw WalkError("menu wants a path") }
            guard let bar = NSApp.mainMenu else { throw WalkError("no menu bar") }
            return try menu(path, in: bar)
        case "context":
            // A row's context menu (#1123), as a right click on its middle builds it, and an
            // item of it chosen; no menu is shown, so nothing waits on its tracking.
            let path = request["path"] as? [String] ?? []
            guard let match = try matches(request).last else { throw WalkError("nothing matched \(request["text"] ?? "")") }
            let window = match.window, box = match.element.frame(in: window)
            guard box != .zero, let root = window.contentView?.superview else { throw WalkError("\(match.element.line(in: window)) has no frame") }
            let point = CGPoint(x: box.midX, y: window.frame.height - box.midY)
            guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                 clickCount: 1, pressure: 1) else { throw WalkError("no event") }
            var view = root.hitTest(root.convert(point, from: nil))
            while let current = view {
                if let found = current.menu(for: event) {
                    guard path.isEmpty else { return try menu(path, in: found) }
                    found.update()
                    return ["ok": true, "did": found.items.filter { !$0.isSeparatorItem }
                        .map { $0.title + ($0.isEnabled ? "" : " (off)") }.joined(separator: "\n")]
                }
                view = current.superview
            }
            throw WalkError("\(match.element.line(in: window)) has no context menu")
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
         "key": window.isKeyWindow, "class": window.className, "number": window.windowNumber,
         "identifier": window.identifier?.rawValue ?? "", "visible": window.isVisible, "minimised": window.isMiniaturized]
    }

    /// A window by words of its title, minimised or not; else as `target` finds one.
    private static func anyWindow(_ request: [String: Any]) throws -> NSWindow {
        guard let title = request["window"] as? String else { return try target(request) }
        guard let window = NSApp.windows.first(where: { $0.title.localizedCaseInsensitiveContains(title) }) else {
            throw WalkError("no window titled \(title)")
        }
        return window
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
        guard request["window"] != nil else {
            // A popover is a child window, which a window that is not on screen keeps out
            // of the app's ordered windows (#1078): its choices are searched first.
            let listed = windows()
            let children = listed.flatMap { $0.childWindows.orEmpty }.filter { child in
                child.isVisible && !listed.contains { $0 === child }
            }
            return children + listed
        }
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

    /// The element under a point of the window (in its points from the top left), as the AX
    /// server's hit test finds it, pressed, or the nearest of its parents that takes a press:
    /// for a control SwiftUI leaves out of the tree it hands out (#1078: the pills over the
    /// prompt). A click would not do: a window that is not key keeps a button's first click.
    private static func pressAt(_ window: NSWindow, _ point: CGPoint) throws -> [String: Any] {
        let onScreen = window.convertPoint(toScreen: CGPoint(x: point.x, y: window.frame.height - point.y))
        guard let root = window.contentView?.superview,
              let hit = root.accessibilityHitTest(onScreen) as? NSObject else {
            throw WalkError("nothing at \(Int(point.x)),\(Int(point.y))")
        }
        var current: WalkAX? = WalkAX(object: hit)
        var hops = 0
        while let element = current, !element.isWindow, hops <= 6 {
            if element.press() { return ["ok": true, "did": "pressed: \(element.line(in: window))"] }
            current = element.parent
            hops += 1
        }
        throw WalkError("nothing at \(Int(point.x)),\(Int(point.y)) takes a press: \(WalkAX(object: hit).line(in: window))")
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

    private static func menu(_ path: [String], in start: NSMenu) throws -> [String: Any] {
        var menu = start
        for (at, title) in path.enumerated() {
            // As opening it does: SwiftUI brings a menu's items up to date only then, so
            // one never opened kept the state it was made with (#1078: Open in Browser off).
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            guard let index = menu.items.firstIndex(where: { $0.title.localizedCaseInsensitiveCompare(title) == .orderedSame })
                ?? menu.items.firstIndex(where: { $0.title.localizedCaseInsensitiveContains(title) }) else {
                throw WalkError("no menu item \(title); there are \(menu.items.map(\.title).filter { !$0.isEmpty })")
            }
            let item = menu.items[index]
            if at == path.count - 1, let items = item.submenu?.items {
                // A menu, not an item: say what is in it.
                if let submenu = item.submenu { submenu.delegate?.menuNeedsUpdate?(submenu) }
                item.submenu?.update()
                // Separators and hidden items too: a blank row in a menu is one of them (#2384).
                return ["ok": true, "did": items.map {
                    ($0.isSeparatorItem ? "—" : $0.title) + ($0.isEnabled || $0.isSeparatorItem ? "" : " (off)")
                        + ($0.isHidden ? " (hidden)" : "")
                }.joined(separator: "\n")]
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
        WalkBox(rect).dictionary
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
