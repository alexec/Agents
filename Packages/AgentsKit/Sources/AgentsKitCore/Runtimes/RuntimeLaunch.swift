import Foundation

/// What a runtime needs at launch beyond its command, kept here as data so that nothing
/// outside the catalogs branches on a runtime's id (049). Most runtimes need none of it.
///
/// Not part of `Runtime`, which travels to the phone and to older daemons: this is only
/// ever read by the daemon that starts the process and by the Mac's sign-in sheet.
public struct RuntimeLaunch: Hashable, Sendable {
    public var runtimeID: String
    /// Set on the runtime's process only. A `nil` value removes the variable, so a stray
    /// one in the daemon's own environment is never used by accident. `<root>` in a value
    /// is the daemon's root (a server's is its `~/.agents-server`).
    public var environment: [String: String?] = [:]
    /// Sign-in methods the runtime offers that the app does not (049: Antigravity's API key
    /// and Agent Platform, because Antigravity signs in with a Google account only). Left
    /// off every sign-in sheet, the Mac's and the phone's.
    public var hiddenAuthMethods: [String] = []
    /// The starts of an agent message that mean the turn failed, for a runtime that says
    /// so in words and then ends the turn normally. First match wins.
    public var turnErrorPrefixes: [String] = []
    /// The first of `turnErrorPrefixes`, for callers that only need to know whether any
    /// failure prefix is configured (so they collect turn text).
    public var turnErrorPrefix: String? { turnErrorPrefixes.first }
    /// An anchored runtime notice that may precede a failure in the concatenated
    /// message chunks. Never search arbitrary assistant prose for error words.
    public var turnNoticePattern: String?
    /// Words the sign-in sheet shows beside some of the runtime's own sign-in methods.
    public var signInNotice: SignInNotice?
    /// Whether the handshake asks for the runtime's sign-in command the older way,
    /// `clientCapabilities._meta["terminal-auth"]` (049: OpenCode names its command only then).
    public var asksForTerminalAuthCommand: Bool = false
    /// For a runtime whose sign-in adds one provider at a time and works with none (049:
    /// OpenCode's free models): the sign-in stays on the sheet while it is ready, and the
    /// sheet names how to sign a provider out — the sign-in command with its last word
    /// swapped for this one — since the runtime has no sign-out over ACP.
    public var providerSignOutWord: String? = nil
    /// The Mac's sign-in a server run of this runtime borrows (049 D7: OpenCode's `auth.json`).
    public var lentSignIn: LentFileSignIn? = nil

    /// The command that signs a provider out, from the command that signs one in.
    public func providerSignOutCommand(from signIn: String) -> String? {
        guard let providerSignOutWord, let space = signIn.lastIndex(of: " ") else { return nil }
        return signIn[..<space] + " " + providerSignOutWord
    }

    public struct SignInNotice: Hashable, Sendable {
        /// Quoted as it is.
        public var text: String
        public var link: URL
        public var linkTitle: String
        /// The auth method ids it is shown beside.
        public var methods: [String]

        public init(text: String, link: URL, linkTitle: String, methods: [String]) {
            self.text = text
            self.link = link
            self.linkTitle = linkTitle
            self.methods = methods
        }
    }

    public init(runtimeID: String, environment: [String: String?] = [:], hiddenAuthMethods: [String] = [],
                turnErrorPrefix: String? = nil, turnErrorPrefixes: [String] = [],
                turnNoticePattern: String? = nil, signInNotice: SignInNotice? = nil,
                asksForTerminalAuthCommand: Bool = false, providerSignOutWord: String? = nil,
                lentSignIn: LentFileSignIn? = nil) {
        self.runtimeID = runtimeID
        self.environment = environment
        self.hiddenAuthMethods = hiddenAuthMethods
        self.turnErrorPrefixes = !turnErrorPrefixes.isEmpty ? turnErrorPrefixes
            : turnErrorPrefix.map { [$0] } ?? []
        self.turnNoticePattern = turnNoticePattern
        self.signInNotice = signInNotice
        self.asksForTerminalAuthCommand = asksForTerminalAuthCommand
        self.providerSignOutWord = providerSignOutWord
        self.lentSignIn = lentSignIn
    }

    /// What a turn's own words say about how it failed, when they start with one of
    /// `turnErrorPrefixes`; nil when they do not.
    public func turnError(in text: String) -> TurnError? {
        guard !turnErrorPrefixes.isEmpty else { return nil }
        var said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let turnNoticePattern,
           let notice = said.range(of: turnNoticePattern, options: [.regularExpression, .anchored]) {
            said.removeSubrange(notice)
            said = said.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let prefix = turnErrorPrefixes.first(where: { said.hasPrefix($0) }) else { return nil }
        return TurnError(sentence: Self.innermost(said, after: prefix))
    }

    public struct TurnError: Hashable, Sendable {
        public var sentence: String
    }

    /// `Agent execution error: Agent execution terminated due to error. ("request failed
    /// (code 400): API key not valid. Please pass a valid API key.")` says, in the end,
    /// "API key not valid. Please pass a valid API key." The last parenthesised quote if
    /// there is one, without a `request failed (code N):` in front; otherwise what follows
    /// the prefix.
    static func innermost(_ text: String, after prefix: String) -> String {
        var said = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = said.range(of: "(\"", options: .backwards),
           let close = said.range(of: "\")", options: .backwards), open.upperBound <= close.lowerBound {
            said = String(said[open.upperBound..<close.lowerBound])
        }
        if let failed = said.range(of: #"^request failed \(code \d+\):\s*"#, options: .regularExpression) {
            said.removeSubrange(failed)
        }
        return said.isEmpty ? text : said
    }

    /// Where `<root>` stands in an environment value.
    public static let rootPlaceholder = "<root>"

    /// `environment` applied on top of `base`, with `<root>` replaced by `root`.
    public func environment(over base: [String: String], root: String) -> [String: String] {
        var result = base
        for (name, value) in environment {
            if let value {
                result[name] = value.replacingOccurrences(of: Self.rootPlaceholder, with: root)
            } else {
                result.removeValue(forKey: name)
            }
        }
        return result
    }

    /// The folders `environment` names under `<root>`, which the daemon makes (0700)
    /// before launch: a runtime whose home or temporary folder is missing may refuse to
    /// start or make it world-readable.
    public func folders(root: String) -> [String] {
        environment.compactMap { name, value in
            guard name.hasSuffix("_HOME") || name == "TMPDIR", let value,
                  value.hasPrefix(Self.rootPlaceholder) else { return nil }
            return value.replacingOccurrences(of: Self.rootPlaceholder, with: root)
        }
        .sorted()
    }
}

public enum RuntimeLaunchCatalog {
    /// Cursor's subscription exhaustion is an ordinary assistant message ending in
    /// `end_turn`, not an ACP failure. Captured from the prompt refusal on 2026-09-28.
    public static let cursor = RuntimeLaunch(
        runtimeID: "cursor",
        turnErrorPrefix: LimitRecognition.cursorPlanExhausted)

    /// Google's Antigravity ACP server (049, research R5–R10).
    ///
    /// - `GEMINI_HOME`: the server roots everything it keeps — settings, conversations,
    ///   sign-in choice, the person's global hooks, skills and MCP servers — at this, and
    ///   says it exists so "an embedding IDE" can isolate itself. So the person's
    ///   `~/.gemini` is never read or written, and each daemon root has its own.
    /// - `AGY_ACP_DISABLE_WORKSPACE_TRUST`: the agent's folder is trusted for this process,
    ///   as Gemini's `--skip-trust` (046 D7), writing nothing of the server's.
    /// - `AGY_ACP_FORCE_FILE_STORAGE`: see D8.
    /// - `GOOGLE_API_KEY`/`GEMINI_API_KEY` removed, so neither Agent Platform nor a key in
    ///   the daemon's environment is picked up behind the person's back. Antigravity signs in
    ///   with a Google account only, and the Gemini key in Settings is Gemini's (Alex,
    ///   2026-09-26: not shared).
    /// - A failed turn arrives as an agent message, `Agent execution error: …`, then
    ///   `end_turn` (R9). A spent plan arrives the same way as `Usage Limit Reached` plus
    ///   the quota sentence (captured 2026-09-27 from “hi Antigravity”).
    public static let antigravity = RuntimeLaunch(
        runtimeID: "antigravity",
        environment: [
            "GEMINI_HOME": "<root>/runtimes/antigravity/home",
            "AGY_ACP_DISABLE_WORKSPACE_TRUST": "1",
            // The Google sign-in as a private file under GEMINI_HOME rather than a Keychain
            // item of the server's, so the app can copy it to a server without a Keychain
            // prompt (049 D8, FR-018a). Linux always keeps it as that file anyway.
            "AGY_ACP_FORCE_FILE_STORAGE": "1",
            "GOOGLE_API_KEY": nil,
            "GEMINI_API_KEY": nil,
        ],
        hiddenAuthMethods: ["gemini-api-key", "agent-platform"],
        turnErrorPrefixes: [
            "Agent execution error:",
            LimitRecognition.antigravityUsageLimitTitle,
        ],
        signInNotice: RuntimeLaunch.SignInNotice(
            text: "“Using third party software, tools, or services to access the Service (e.g. using "
                + "OpenClaw with Antigravity OAuth) is a breach of this Agreement.”",
            link: URL(string: "https://antigravity.google/terms")!,
            linkTitle: "Read Google’s terms",
            methods: ["oauth-personal", "oauth-business"]))

    /// Copilot reports failures as `Error: …` chat text followed by `end_turn`.
    /// Observed on 2026-09-26 for its exhausted monthly quota.
    public static let copilot = RuntimeLaunch(
        runtimeID: "copilot", turnErrorPrefix: "Error:",
        // ACP sends this notice without a trailing newline, before any error chunks.
        turnNoticePattern: #"^Info: Disabled tools: [a-z_][a-z_0-9]*(?:, [a-z_][a-z_0-9]*)*"#)

    /// OpenCode (049, research R3, R7).
    ///
    /// - `OPENCODE_DISABLE_AUTOUPDATE`, `OPENCODE_DISABLE_SHARE`: the same as the inline
    ///   config's `autoupdate` and `share`, as switches that a person's own config cannot
    ///   turn back on.
    /// - `OPENCODE_AUTH_CONTENT` removed: on the Mac, OpenCode uses its own sign-in in the
    ///   person's home (D3). A server run is lent the Mac's through this variable, set after
    ///   this by the lending (D7), never from a stray one in the daemon's environment.
    /// - `OPENCODE_ENABLE_QUESTION_TOOL` removed: questions go through the app's `ask_form`.
    /// - `TMPDIR` of its own: at the start of every turn OpenCode walks its temporary folder,
    ///   and a Mac's per-user one can hold close to a million entries. Measured on this Mac on
    ///   2026-09-29: 40 s before the first word with `/var/folders/…/T/`, 2 s with an empty
    ///   folder, the same model and prompt otherwise (research R11).
    public static let opencode = RuntimeLaunch(
        runtimeID: "opencode",
        environment: [
            "TMPDIR": "<root>/runtimes/opencode/tmp",
            "OPENCODE_DISABLE_AUTOUPDATE": "1",
            "OPENCODE_DISABLE_SHARE": "1",
            "OPENCODE_AUTH_CONTENT": nil,
            "OPENCODE_ENABLE_QUESTION_TOOL": nil,
        ],
        // Without it OpenCode offers "Login with opencode" and no command (R6).
        asksForTerminalAuthCommand: true,
        // `opencode auth login` adds a provider; `opencode auth logout` takes one away.
        providerSignOutWord: "logout",
        // A server run borrows the Mac's keys (D7). `oauth` entries rotate and stay (R7).
        lentSignIn: LentFileSignIn(variable: "OPENCODE_AUTH_CONTENT", dataHomeVariable: "XDG_DATA_HOME",
                                   dataHomePath: "opencode/auth.json",
                                   defaultPath: ".local/share/opencode/auth.json",
                                   lendableTypes: ["api", "wellknown"], signInCommand: "opencode auth login"))

    public static let builtIn: [RuntimeLaunch] = [antigravity, copilot, cursor, opencode]

    /// Nothing extra for a runtime that is not listed.
    public static func launch(for runtimeID: String) -> RuntimeLaunch {
        builtIn.first { $0.runtimeID == runtimeID } ?? RuntimeLaunch(runtimeID: runtimeID)
    }
}
