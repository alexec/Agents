import Foundation

/// The host's half of a view's conversation (#187): JSON-RPC 2.0 over `postMessage`, as
/// MCP Apps (SEP-1865) has it. What a view says is read here into one `Ask`; what the host
/// says back is built here. The renderers — the Mac's and the phone's web views — only
/// carry the messages and do what an `Ask` says. The web page's copy of this is
/// `Web/src/views/chat/appViewBridge.ts`, and the two are kept in step by
/// `docs/explanation/views.md`.
public enum AppViewBridge {
    /// The version of MCP Apps this host speaks.
    public static let protocolVersion = "2026-01-26"

    /// What a view asked for, read.
    public enum Ask: Equatable, Sendable {
        case initialize(id: JSONValue)
        case initialized
        case ping(id: JSONValue)
        case callTool(id: JSONValue, name: String, arguments: JSONValue?)
        case readResource(id: JSONValue, uri: String)
        case openLink(id: JSONValue, url: URL)
        case message(id: JSONValue, text: String)
        case updateContext(id: JSONValue, content: JSONValue?, structuredContent: JSONValue?)
        case displayMode(id: JSONValue, mode: String)
        case sizeChanged(width: Double?, height: Double?)
        case log(level: String?, data: JSONValue?)
        /// The answer to the host's `ui/resource-teardown`.
        case answered(id: JSONValue)
        /// A request the host does not do: answered -32601.
        case unknown(id: JSONValue, method: String)
        /// A request whose parameters were wrong: answered -32602, with why.
        case malformed(id: JSONValue, reason: String)
        /// Anything else: a notification nobody acts on, or not JSON-RPC at all.
        case ignored
    }

    public static func read(_ message: JSONValue) -> Ask {
        guard message["jsonrpc"]?.stringValue == "2.0" else { return .ignored }
        let id = message["id"]
        let params = message["params"]
        guard let method = message["method"]?.stringValue else {
            // A response: the only request the host sends a view is the teardown.
            if let id, message["result"] != nil || message["error"] != nil { return .answered(id: id) }
            return .ignored
        }
        guard let id, !id.isNull else {
            switch method {
            case "ui/notifications/initialized":
                return .initialized
            case "ui/notifications/size-changed":
                return .sizeChanged(width: params?["width"].flatMap(number), height: params?["height"].flatMap(number))
            case "notifications/message":
                return .log(level: params?["level"]?.stringValue, data: params?["data"])
            default:
                return .ignored
            }
        }
        switch method {
        case "ui/initialize", "initialize":
            return .initialize(id: id)
        case "ping":
            return .ping(id: id)
        case "tools/call":
            guard let name = params?["name"]?.stringValue, !name.isEmpty else {
                return .malformed(id: id, reason: "tools/call needs a name.")
            }
            return .callTool(id: id, name: name, arguments: params?["arguments"])
        case "resources/read":
            guard let uri = params?["uri"]?.stringValue, !uri.isEmpty else {
                return .malformed(id: id, reason: "resources/read needs a uri.")
            }
            return .readResource(id: id, uri: uri)
        case "ui/open-link":
            guard let text = params?["url"]?.stringValue, let url = URL(string: text),
                  ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else {
                return .malformed(id: id, reason: "Only an http, https or mailto link can be opened.")
            }
            return .openLink(id: id, url: url)
        case "ui/message":
            let blocks = params?["content"].map { $0.arrayValue ?? [$0] } ?? []
            let text = blocks.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return .malformed(id: id, reason: "ui/message needs text content.") }
            return .message(id: id, text: text)
        case "ui/update-model-context":
            return .updateContext(id: id, content: params?["content"], structuredContent: params?["structuredContent"])
        case "ui/request-display-mode":
            return .displayMode(id: id, mode: params?["mode"]?.stringValue ?? "")
        default:
            return .unknown(id: id, method: method)
        }
    }

    private static func number(_ value: JSONValue) -> Double? {
        switch value {
        case .int(let n): return Double(n)
        case .double(let n): return n
        default: return nil
        }
    }

    // MARK: What the host says

    public static func result(_ id: JSONValue, _ value: JSONValue = [:]) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": value]
    }

    public static func error(_ id: JSONValue, code: Int, _ message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }

    public static func notification(_ method: String, _ params: JSONValue = [:]) -> JSONValue {
        ["jsonrpc": "2.0", "method": .string(method), "params": params]
    }

    public static func request(_ id: JSONValue, _ method: String, _ params: JSONValue = [:]) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "method": .string(method), "params": params]
    }

    /// The answer to `ui/initialize`.
    public static func initializeResult(_ context: AppViewContext, policy: AppViewPolicy) -> JSONValue {
        [
            "protocolVersion": .string(protocolVersion),
            "hostInfo": ["name": "agents", "version": "1.0.0"],
            "hostCapabilities": [
                "openLinks": [:],
                "serverTools": [:],
                "serverResources": [:],
                "logging": [:],
                "sandbox": ["permissions": [:], "csp": policy.wire],
            ],
            "hostContext": context.wire,
        ]
    }

    /// The display modes every host of this app offers. `pip` is not one.
    public static let displayModes = ["inline", "fullscreen"]

    /// The text a view's model context is told to the agent in, before the person's words.
    public static func contextPreface(viewTitle: String, content: JSONValue?, structuredContent: JSONValue?) -> String? {
        var parts: [String] = []
        for block in content?.arrayValue ?? [] {
            if block["type"]?.stringValue == "text", let text = block["text"]?.stringValue,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(text)
            }
        }
        if let structuredContent, !structuredContent.isNull,
           let data = try? JSONEncoder().encode(structuredContent) {
            parts.append(String(decoding: data, as: UTF8.self))
        }
        guard !parts.isEmpty else { return nil }
        let body = String(parts.joined(separator: "\n").prefix(contextLimit))
        return "The view “\(viewTitle)” in this conversation gave you this context, as the person last left it:\n\(body)"
    }

    /// The most of a view's context told to the agent, in characters.
    public static let contextLimit = 8000
}

/// What the host tells a view about where it is drawn (`hostContext`).
public struct AppViewContext: Equatable, Sendable {
    public enum Platform: String, Sendable { case web, desktop, mobile }

    public var theme: String
    public var platform: Platform
    public var displayMode: String
    /// Fixed width; height up to `maxHeight` inline, fixed when fullscreen.
    public var width: Double
    public var height: Double?
    public var maxHeight: Double?
    public var locale: String
    public var timeZone: String
    public var safeAreaInsets: (top: Double, right: Double, bottom: Double, left: Double)
    public var touch: Bool
    public var hover: Bool
    public var toolInfo: JSONValue?

    public init(theme: String, platform: Platform, displayMode: String = "inline",
                width: Double, height: Double? = nil, maxHeight: Double? = nil,
                locale: String = Locale.current.identifier(.bcp47),
                timeZone: String = TimeZone.current.identifier,
                safeAreaInsets: (top: Double, right: Double, bottom: Double, left: Double) = (0, 0, 0, 0),
                touch: Bool, hover: Bool, toolInfo: JSONValue? = nil) {
        self.theme = theme
        self.platform = platform
        self.displayMode = displayMode
        self.width = width
        self.height = height
        self.maxHeight = maxHeight
        self.locale = locale
        self.timeZone = timeZone
        self.safeAreaInsets = safeAreaInsets
        self.touch = touch
        self.hover = hover
        self.toolInfo = toolInfo
    }

    public static func == (a: AppViewContext, b: AppViewContext) -> Bool {
        a.wire == b.wire
    }

    public var dimensions: JSONValue {
        var fields: [String: JSONValue] = ["width": .double(width.rounded())]
        if let height { fields["height"] = .double(height.rounded()) }
        else if let maxHeight { fields["maxHeight"] = .double(maxHeight.rounded()) }
        return .object(fields)
    }

    public var wire: JSONValue {
        var fields: [String: JSONValue] = [
            "theme": .string(theme),
            "platform": .string(platform.rawValue),
            "displayMode": .string(displayMode),
            "availableDisplayModes": .array(AppViewBridge.displayModes.map(JSONValue.string)),
            "containerDimensions": dimensions,
            "locale": .string(locale),
            "timeZone": .string(timeZone),
            "userAgent": "agents",
            "deviceCapabilities": ["touch": .bool(touch), "hover": .bool(hover)],
            "safeAreaInsets": ["top": .double(safeAreaInsets.top), "right": .double(safeAreaInsets.right),
                               "bottom": .double(safeAreaInsets.bottom), "left": .double(safeAreaInsets.left)],
            "styles": ["variables": .object(AppViewTheme.variables.mapValues(JSONValue.string))],
        ]
        if let toolInfo { fields["toolInfo"] = toolInfo }
        return .object(fields)
    }

    /// The fields that differ from `before`, for `ui/notifications/host-context-changed`.
    /// Nil when nothing did.
    public func changes(since before: AppViewContext) -> JSONValue? {
        guard let now = wire.objectValue, let was = before.wire.objectValue else { return nil }
        let changed = now.filter { was[$0.key] != $0.value }
        return changed.isEmpty ? nil : .object(changed)
    }
}

/// What the host owes a view about its call, in order: the input once the view has said it
/// is initialized, then the result or the cancellation. A later result — a Dashboard that
/// changed while it stayed open — is said again. A cancellation is not followed by a result.
public struct AppViewFeed: Equatable, Sendable {
    public private(set) var initialized = false
    public private(set) var sentInput = false
    public private(set) var sentEnd = false
    /// The result last given to the view. Nil when what ended the call was a cancellation.
    private var sentResult: JSONValue?

    public init() {}

    /// The view said `ui/notifications/initialized`.
    public mutating func viewInitialized(_ call: AppViewCall) -> [JSONValue] {
        initialized = true
        return due(call)
    }

    /// The call as it now stands: whatever is newly due.
    public mutating func due(_ call: AppViewCall) -> [JSONValue] {
        guard initialized else { return [] }
        var out: [JSONValue] = []
        if !sentInput {
            sentInput = true
            out.append(AppViewBridge.notification("ui/notifications/tool-input",
                                                  ["arguments": call.arguments ?? [:]]))
        }
        switch call.state {
        case .running:
            break
        case .done:
            let result = call.result ?? ["content": []]
            // A cancellation already closed this call. A new result, after one was shown,
            // is the Dashboard changing under an open view (#188).
            if !sentEnd {
                sentEnd = true
                sentResult = result
                out.append(AppViewBridge.notification("ui/notifications/tool-result", result))
            } else if sentResult != nil, sentResult != result {
                sentResult = result
                out.append(AppViewBridge.notification("ui/notifications/tool-result", result))
            }
        case .cancelled:
            if !sentEnd {
                sentEnd = true
                out.append(AppViewBridge.notification("ui/notifications/tool-cancelled",
                                                      ["reason": .string(call.reason ?? "The turn was stopped.")]))
            }
        }
        return out
    }
}
