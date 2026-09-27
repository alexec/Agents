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
    /// The start of an agent message that means the turn failed, for a runtime that says
    /// so in words and then ends the turn normally.
    public var turnErrorPrefix: String?
    /// Words the sign-in sheet shows beside some of the runtime's own sign-in methods.
    public var signInNotice: SignInNotice?

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
                turnErrorPrefix: String? = nil, signInNotice: SignInNotice? = nil) {
        self.runtimeID = runtimeID
        self.environment = environment
        self.hiddenAuthMethods = hiddenAuthMethods
        self.turnErrorPrefix = turnErrorPrefix
        self.signInNotice = signInNotice
    }

    /// What a turn's own words say about how it failed, when they start with
    /// `turnErrorPrefix`; nil when they do not.
    public func turnError(in text: String) -> TurnError? {
        guard let turnErrorPrefix else { return nil }
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard said.hasPrefix(turnErrorPrefix) else { return nil }
        return TurnError(sentence: Self.innermost(said, after: turnErrorPrefix))
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
        var said = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
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
    /// before launch: a runtime whose home is missing may refuse to start or make it
    /// world-readable.
    public func folders(root: String) -> [String] {
        environment.compactMap { name, value in
            guard name.hasSuffix("_HOME"), let value, value.hasPrefix(Self.rootPlaceholder) else { return nil }
            return value.replacingOccurrences(of: Self.rootPlaceholder, with: root)
        }
        .sorted()
    }
}

public enum RuntimeLaunchCatalog {
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
    ///   `end_turn` (R9).
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
        turnErrorPrefix: "Agent execution error:",
        signInNotice: RuntimeLaunch.SignInNotice(
            text: "“Using third party software, tools, or services to access the Service (e.g. using "
                + "OpenClaw with Antigravity OAuth) is a breach of this Agreement.”",
            link: URL(string: "https://antigravity.google/terms")!,
            linkTitle: "Read Google’s terms",
            methods: ["oauth-personal", "oauth-business"]))

    /// Copilot reports failures as `Error: …` chat text followed by `end_turn`.
    /// Observed on 2026-09-26 for its exhausted monthly quota.
    public static let copilot = RuntimeLaunch(runtimeID: "copilot", turnErrorPrefix: "Error:")

    public static let builtIn: [RuntimeLaunch] = [antigravity, copilot]

    /// Nothing extra for a runtime that is not listed.
    public static func launch(for runtimeID: String) -> RuntimeLaunch {
        builtIn.first { $0.runtimeID == runtimeID } ?? RuntimeLaunch(runtimeID: runtimeID)
    }
}
