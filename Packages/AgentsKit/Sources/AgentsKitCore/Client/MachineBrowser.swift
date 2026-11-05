import CoreGraphics
import Foundation
import Observation

/// A window's view of one machine's browser (#3528, spike #3527): the page an agent drives,
/// as a screencast from that machine's host, and the person's clicks, keys and the bar's
/// buttons sent back to it.
///
/// One per host per window. Each pane that shows it says `watch` while on screen and
/// `unwatch` when it goes; the host sends frames while any does. A frame is acked as it
/// lands, so the host sends the next only then, and a slow link gets fewer frames rather
/// than a backlog.
@MainActor
@Observable
public final class MachineBrowser {
    public private(set) var state = DaemonAPI.BrowserState(status: .stopped)
    /// The newest frame: a JPEG, and the page's size in CSS pixels.
    public private(set) var frame: DaemonAPI.BrowserFrame?
    /// A call that failed, said under the page; cleared by the next one that works.
    public private(set) var problem: String?

    private let client: DaemonClient
    private let describe: @MainActor (any Error) -> String
    /// How many panes watch, and the size the last one asked for.
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var size: (width: Int, height: Int) = (0, 0)
    /// The person's input, sent one call at a time, in order.
    @ObservationIgnored private var outbox: [DaemonAPI.BrowserInputRequest] = []
    @ObservationIgnored private var sender: Task<Void, Never>?

    public init(client: DaemonClient, describe: @escaping @MainActor (any Error) -> String) {
        self.client = client
        self.describe = describe
    }

    /// A pane came on screen at this size, in points, or changed size.
    public func watch(width: Int, height: Int, adding: Bool) async {
        if adding { watchers += 1 }
        guard watchers > 0, width > 0, height > 0 else { return }
        size = (width, height)
        await sayWatch()
    }

    private func sayWatch() async {
        do {
            state = try await client.call(DaemonAPI.Method.browserWatch,
                                          DaemonAPI.BrowserWatchRequest(width: size.width, height: size.height),
                                          returning: DaemonAPI.BrowserState.self)
            problem = nil
        } catch {
            problem = describe(error)
        }
    }

    /// A pane went off screen. The last one to go stops the frames.
    public func unwatch() async {
        guard watchers > 0 else { return }
        watchers -= 1
        guard watchers == 0 else { return }
        frame = nil
        _ = try? await client.call(DaemonAPI.Method.browserUnwatch, DaemonAPI.Empty())
    }

    /// A new connection: the host forgot this window's watch with the old one.
    public func rewatchIfWatching() async {
        guard watchers > 0, size.width > 0 else { return }
        await sayWatch()
    }

    /// browser/frame or browser/state from this host.
    public func received(_ method: String, _ params: JSONValue?) {
        switch method {
        case DaemonAPI.Notification.browserFrame:
            guard watchers > 0, let f = try? params?.decode(DaemonAPI.BrowserFrame.self) else { return }
            frame = f
            Task { _ = try? await self.client.call(DaemonAPI.Method.browserAck, DaemonAPI.BrowserAckRequest(ack: f.ack)) }
        case DaemonAPI.Notification.browserState:
            guard let s = try? params?.decode(DaemonAPI.BrowserState.self) else { return }
            state = s
            if s.status != .running { frame = nil }
        default:
            break
        }
    }

    /// The person's input, queued and sent in order. A move waiting behind another move is
    /// replaced by it: only where the pointer is now matters.
    public func send(_ input: DaemonAPI.BrowserInputRequest) {
        guard state.status == .running else { return }
        if input.kind == .mouse, input.type == "mouseMoved", let last = outbox.last,
           last.kind == .mouse, last.type == "mouseMoved" {
            outbox[outbox.count - 1] = input
        } else {
            outbox.append(input)
        }
        guard sender == nil else { return }
        sender = Task { await self.drain() }
    }

    private func drain() async {
        while !outbox.isEmpty {
            let next = outbox.removeFirst()
            do {
                _ = try await client.call(DaemonAPI.Method.browserInput, next)
                problem = nil
            } catch {
                // Input queued behind a failure is not sent later, out of context.
                outbox.removeAll()
                problem = describe(error)
            }
        }
        sender = nil
    }

    /// Back, Forward, Reload, or an address typed in the bar.
    public func navigate(_ action: DaemonAPI.BrowserNavigateAction, to address: String? = nil) async {
        do {
            _ = try await client.call(DaemonAPI.Method.browserNavigate,
                                      DaemonAPI.BrowserNavigateRequest(action: action, url: address))
            problem = nil
        } catch {
            problem = describe(error)
        }
    }

    /// Where in the page a point of the view is, in CSS pixels, when the page is drawn to
    /// fit the view and centred in it; nil outside the page.
    public nonisolated static func pagePoint(_ point: CGPoint, in view: CGSize, page: CGSize) -> CGPoint? {
        let fit = fitted(page, in: view)
        guard fit.width > 0, fit.height > 0, fit.contains(point) else { return nil }
        return CGPoint(x: (point.x - fit.minX) * page.width / fit.width,
                       y: (point.y - fit.minY) * page.height / fit.height)
    }

    /// The rectangle a page of this size takes when drawn to fit the view, centred.
    public nonisolated static func fitted(_ page: CGSize, in view: CGSize) -> CGRect {
        guard page.width > 0, page.height > 0, view.width > 0, view.height > 0 else { return .zero }
        let scale = min(view.width / page.width, view.height / page.height)
        let size = CGSize(width: page.width * scale, height: page.height * scale)
        return CGRect(x: (view.width - size.width) / 2, y: (view.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

/// A key on a Mac keyboard as the page's key events name it (#3528): the DOM `key` and
/// `code`, and the Windows virtual key code Chromium needs to act on keys with no text.
public enum BrowserKeys {
    /// Keys with no text, by the Mac's virtual key code.
    static let named: [UInt16: (key: String, code: String, keyCode: Int)] = [
        36: ("Enter", "Enter", 13), 76: ("Enter", "NumpadEnter", 13), 48: ("Tab", "Tab", 9),
        51: ("Backspace", "Backspace", 8), 117: ("Delete", "Delete", 46), 53: ("Escape", "Escape", 27),
        123: ("ArrowLeft", "ArrowLeft", 37), 124: ("ArrowRight", "ArrowRight", 39),
        125: ("ArrowDown", "ArrowDown", 40), 126: ("ArrowUp", "ArrowUp", 38),
        115: ("Home", "Home", 36), 119: ("End", "End", 35), 116: ("PageUp", "PageUp", 33),
        121: ("PageDown", "PageDown", 34), 49: (" ", "Space", 32),
    ]

    /// The modifier bits CDP takes: Alt 1, Control 2, Meta 4, Shift 8.
    public static func modifiers(option: Bool, control: Bool, command: Bool, shift: Bool) -> Int {
        (option ? 1 : 0) | (control ? 2 : 0) | (command ? 4 : 0) | (shift ? 8 : 0)
    }

    /// A key going down or up. `characters` is what it types, `bare` what it types with no
    /// modifier but Shift (the key's own letter), `macKeyCode` the Mac's virtual key code.
    public static func input(down: Bool, characters: String, bare: String, macKeyCode: UInt16,
                             modifiers: Int) -> DaemonAPI.BrowserInputRequest {
        let type = down ? "keyDown" : "keyUp"
        if let n = named[macKeyCode] {
            // Space types a space; the others type nothing.
            let text = down && n.key == " " ? " " : nil
            return DaemonAPI.BrowserInputRequest(kind: .key, type: type, key: n.key, code: n.code,
                                                 keyCode: n.keyCode, text: text, modifiers: modifiers)
        }
        let letter = bare.first.map(String.init) ?? characters
        var code: String?
        var keyCode: Int?
        if let c = letter.uppercased().unicodeScalars.first, letter.count == 1 {
            if ("A"..."Z").contains(Character(c)) {
                code = "Key\(Character(c))"
                keyCode = Int(c.value)
            } else if ("0"..."9").contains(Character(c)) {
                code = "Digit\(Character(c))"
                keyCode = Int(c.value)
            }
        }
        // Text goes only with a key that types: not with Command or Control held.
        let types = down && modifiers & (2 | 4) == 0 && !characters.isEmpty
            && characters.unicodeScalars.allSatisfy { $0.value >= 0x20 && !(0xF700...0xF8FF).contains($0.value) }
        return DaemonAPI.BrowserInputRequest(kind: .key, type: type, key: characters.isEmpty ? letter : characters,
                                             code: code, keyCode: keyCode, text: types ? characters : nil,
                                             modifiers: modifiers)
    }
}
