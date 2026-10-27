import Foundation

/// The host's half of a view's conversation (#187): JSON-RPC 2.0 over `postMessage`, as
/// MCP Apps (SEP-1865) has it. What a view says is read here into one `Ask`; what the host
/// says back is built here. The renderers — the Mac's and the phone's web views — only
/// carry the messages and do what an `Ask` says. The web page's copy of this is
/// `Web/src/views/chat/appViewBridge.ts`, and the two are kept in step by
/// `docs/explanation/views.md`.
public enum AppViewBridge {
    /// `hostContext.toolInfo`: the call's tool as an MCP `Tool`, which needs an
    /// `inputSchema`. The ext-apps SDK refuses `ui/initialize` without one (#191 walk).
    public static func toolInfo(_ tool: String) -> JSONValue {
        ["tool": ["name": .string(tool), "inputSchema": ["type": "object"]]]
    }

    /// Our extension of MCP Apps (#834): a view asks for the new-agent form, filled in.
    public static let startAgentMethod = "agents/start-agent"
    /// Our extension of MCP Apps (#837): a view asks to send words to the session working on
    /// a branch. The person says Send first.
    public static let messageAgentMethod = "agents/message-agent"
    /// Our extension of MCP Apps (#1341): a view asks the app to draw a diff, in its own diff
    /// (the Review page's, #1472), not in the view.
    public static let openDiffMethod = "agents/open-diff"
    /// The error code of an `agents/message-agent` that no session in the view's folder
    /// works on: the view may offer a new agent instead.
    public static let noAgentCode = -32001

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
        /// Our extension (#834): open the new-agent form, filled in. Never a start.
        case startAgent(id: JSONValue, start: AppViewStart)
        /// Our extension (#837): send words to the session on a branch, once the person says Send.
        case messageAgent(id: JSONValue, message: AppViewAgentMessage)
        /// Our extension (#1341): draw these files' hunks in the app's own diff.
        case openDiff(id: JSONValue, diff: AppViewDiff)
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
        case startAgentMethod:
            switch AppViewStart.read(params) {
            case .success(let start): return .startAgent(id: id, start: start)
            case .failure(let reason): return .malformed(id: id, reason: reason.words)
            }
        case messageAgentMethod:
            switch AppViewAgentMessage.read(params) {
            case .success(let message): return .messageAgent(id: id, message: message)
            case .failure(let reason): return .malformed(id: id, reason: reason.words)
            }
        case openDiffMethod:
            switch AppViewDiff.read(params) {
            case .success(let diff): return .openDiff(id: id, diff: diff)
            case .failure(let reason): return .malformed(id: id, reason: reason.words)
            }
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

/// What a view filled the new-agent form with (#834, `agents/start-agent`). The form opens
/// in the view's folder, and the person starts the agent, or doesn't.
public struct AppViewStart: Equatable, Sendable {
    /// The prompt, as the person will see it in the field.
    public var prompt: String
    /// Labels set on the form, such as `#834`.
    public var labels: [String]
    /// A new worktree's name, made with `WorktreeChoice.named`; nil leaves the form's place.
    public var worktree: String?
    /// A branch already there, for a new worktree on it (`WorktreeChoice.branch`, #837): a
    /// pull request's. It wins over `worktree`.
    public var branch: String?

    public struct Refusal: Error, Equatable {
        public var words: String
    }

    /// The most a view may put in the field, in characters.
    public static let promptLimit = 8000

    public init(prompt: String, labels: [String] = [], worktree: String? = nil, branch: String? = nil) {
        self.prompt = prompt
        self.labels = labels
        self.worktree = worktree
        self.branch = branch
    }

    /// Where the form puts the new agent, if the view said.
    public var worktreeChoice: WorktreeChoice? {
        if let branch { return .branch(branch) }
        return worktree.map(WorktreeChoice.named)
    }

    /// Read from the message's parameters, or why not.
    public static func read(_ params: JSONValue?) -> Result<AppViewStart, Refusal> {
        let prompt = (params?["prompt"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return .failure(Refusal(words: "agents/start-agent needs a prompt.")) }
        guard prompt.count <= promptLimit else {
            return .failure(Refusal(words: "The prompt is longer than \(promptLimit) characters."))
        }
        var labels: [String] = []
        for value in params?["labels"]?.arrayValue ?? [] {
            // A session's own rules, so the form never holds a label its start would refuse.
            guard let label = try? SessionLabelPolicy.cleaned(value.stringValue ?? "") else {
                return .failure(Refusal(words: "Each label is text of 1 to \(SessionLabelPolicy.maximumLength) characters."))
            }
            if !labels.contains(where: { SessionLabelPolicy.key($0) == SessionLabelPolicy.key(label) }) { labels.append(label) }
        }
        guard labels.count <= SessionLabelPolicy.maximumCount else {
            return .failure(Refusal(words: SessionLabelPolicy.Refusal.tooMany.localizedDescription))
        }
        let worktree = params?["worktree"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = params?["branch"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (branch ?? "").count <= AppViewAgentMessage.branchLimit else {
            return .failure(Refusal(words: "The branch is longer than \(AppViewAgentMessage.branchLimit) characters."))
        }
        return .success(AppViewStart(prompt: prompt, labels: labels,
                                     worktree: worktree.flatMap { $0.isEmpty ? nil : String($0.prefix(100)) },
                                     branch: branch.flatMap { $0.isEmpty ? nil : $0 }))
    }
}

/// What a view asked to send to the session on a branch (#837, `agents/message-agent`): the
/// person is asked under the view, and Send puts it in that session as their prompt.
public struct AppViewAgentMessage: Equatable, Sendable {
    /// The branch the session's worktree is on, such as a pull request's.
    public var branch: String
    /// The words, as the person will see them before Send.
    public var text: String

    public struct Refusal: Error, Equatable {
        public var words: String
    }

    public static let textLimit = AppViewStart.promptLimit
    public static let branchLimit = 255

    public init(branch: String, text: String) {
        self.branch = branch
        self.text = text
    }

    /// Read from the message's parameters, or why not.
    public static func read(_ params: JSONValue?) -> Result<AppViewAgentMessage, Refusal> {
        let branch = (params?["branch"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { return .failure(Refusal(words: "agents/message-agent needs a branch.")) }
        guard branch.count <= branchLimit else {
            return .failure(Refusal(words: "The branch is longer than \(branchLimit) characters."))
        }
        let text = (params?["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(Refusal(words: "agents/message-agent needs text.")) }
        guard text.count <= textLimit else {
            return .failure(Refusal(words: "The text is longer than \(textLimit) characters."))
        }
        return .success(AppViewAgentMessage(branch: branch, text: text))
    }

    /// The session it goes to: one on `host` in `folder` whose worktree is on the branch, not
    /// archived, the latest active first. Nil when there is none.
    public func recipient(among agents: [Agent], host: MachineRef, folder: URL) -> Agent? {
        let folder = Folder.standardize(folder)
        return agents
            .filter { $0.host == host && $0.archivedAt == nil && $0.worktree?.branch == branch && $0.folderPath == folder }
            .max { $0.lastActivityAt < $1.lastActivityAt }
    }

    /// What the person is shown the session as.
    public static func name(of agent: Agent) -> String {
        let title = agent.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? (agent.worktree?.name ?? "the agent") : title
    }
}

/// What a view asked the app to draw in its own diff (#1341, `agents/open-diff`): a pull
/// request's files, each as its hunks, as GitHub gives them. The app draws it on a page of
/// its own, with the diff of the Review page (#1472).
public struct AppViewDiff: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case context, added, removed }

    public struct Line: Equatable, Sendable {
        public var kind: Kind
        public var text: String
    }

    public struct Hunk: Equatable, Sendable {
        public var oldStart: Int
        public var newStart: Int
        public var lines: [Line]
    }

    public struct File: Equatable, Sendable, Identifiable {
        public var path: String
        public var previousPath: String?
        /// added, removed, modified, renamed …, as GitHub says.
        public var change: String
        public var additions: Int
        public var deletions: Int
        public var hunks: [Hunk]
        /// Why it has no hunks, when it has none.
        public var note: String?
        public var id: String { path }
    }

    public var id = UUID()
    public var title: String
    /// Where the same diff is on the web, such as the pull request's Files page.
    public var url: URL?
    public var files: [File]
    /// Whether the view cut it: some files are listed with no hunks.
    public var cut: Bool
    /// The file to show first, when the view named one.
    public var path: String?

    public struct Refusal: Error, Equatable {
        public var words: String
    }

    /// The most lines a diff may have, all files together, and the most files.
    public static let lineLimit = 20_000
    public static let fileLimit = 3000

    public init(title: String, url: URL? = nil, files: [File], cut: Bool = false, path: String? = nil) {
        self.title = title
        self.url = url
        self.files = files
        self.cut = cut
        self.path = path
    }

    public static func == (a: AppViewDiff, b: AppViewDiff) -> Bool {
        a.title == b.title && a.url == b.url && a.files == b.files && a.cut == b.cut && a.path == b.path
    }

    /// Read from the message's parameters, or why not.
    public static func read(_ params: JSONValue?) -> Result<AppViewDiff, Refusal> {
        guard let given = params?["files"]?.arrayValue else {
            return .failure(Refusal(words: "agents/open-diff needs files."))
        }
        guard given.count <= fileLimit else { return .failure(Refusal(words: "A diff has at most \(fileLimit) files.")) }
        var lines = 0
        var files: [File] = []
        for f in given {
            guard let path = f["path"]?.stringValue, !path.isEmpty else {
                return .failure(Refusal(words: "Each file of a diff needs a path."))
            }
            var hunks: [Hunk] = []
            for h in f["hunks"]?.arrayValue ?? [] {
                var hunk = Hunk(oldStart: max(1, h["oldStart"]?.intValue ?? 1), newStart: max(1, h["newStart"]?.intValue ?? 1), lines: [])
                for l in h["lines"]?.arrayValue ?? [] {
                    guard let kind = Kind(rawValue: l["kind"]?.stringValue ?? ""), let text = l["text"]?.stringValue else {
                        return .failure(Refusal(words: "Each line of a diff is context, added or removed, with its text."))
                    }
                    hunk.lines.append(Line(kind: kind, text: text))
                }
                lines += hunk.lines.count
                hunks.append(hunk)
            }
            guard lines <= lineLimit else { return .failure(Refusal(words: "A diff has at most \(lineLimit) lines.")) }
            files.append(File(path: path, previousPath: f["previousPath"]?.stringValue, change: f["change"]?.stringValue ?? "modified",
                              additions: max(0, f["additions"]?.intValue ?? 0), deletions: max(0, f["deletions"]?.intValue ?? 0),
                              hunks: hunks, note: f["note"]?.stringValue))
        }
        let title = (params?["title"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let url = params?["url"]?.stringValue.flatMap(URL.init(string:)).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        return .success(AppViewDiff(title: title.isEmpty ? "Changes" : String(title.prefix(200)), url: url, files: files,
                                    cut: params?["cut"]?.boolValue ?? false, path: params?["path"]?.stringValue))
    }
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
/// is initialized, then the result or the cancellation. A later result — a pinned view fed
/// again while it stayed open — is said again. A cancellation is not followed by a result.
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
            // is what feeds an open view changing under it (#188).
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
