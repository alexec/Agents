import Foundation

/// What sort of credential a pasted string is (043, D1; Gemini's, 046; Codex's, 047).
///
/// Told apart by prefix, because each is handed to its runtime in its own environment
/// variable and checked with its own request. Anything else is refused at paste, with a
/// sentence, rather than saved and found wrong on a server later.
public enum CredentialKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// Made by `claude setup-token` for a subscription: `sk-ant-oat…`.
    case oauthToken
    /// From the Anthropic console: `sk-ant-api…`.
    case apiKey
    /// From Google AI Studio (046): `AIza…`, or `AQ.…` for the keys it issues now. The only
    /// way into Gemini CLI for an individual since Google closed its own sign-in to them.
    case geminiAPIKey
    /// From the OpenAI platform (047): `sk-proj-…`, or plain `sk-…` for older ones. For Codex
    /// on a server whose window has no ChatGPT sign-in to relay; the Mac uses ChatGPT.
    case openAIAPIKey

    public init?(secret: String) {
        let text = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        // Claude's start `sk-ant-` too: one that is neither of Claude's shapes is nobody's.
        guard let kind = Self.allCases.first(where: { kind in kind.prefixes.contains { text.hasPrefix($0) } }),
              kind != .openAIAPIKey || !text.hasPrefix("sk-ant-")
        else { return nil }
        self = kind
    }

    /// The runtime it signs in.
    public var runtimeID: String {
        switch self {
        case .oauthToken, .apiKey: RuntimeCatalog.claude.id
        case .geminiAPIKey: RuntimeCatalog.gemini.id
        case .openAIAPIKey: RuntimeCatalog.codex.id
        }
    }

    /// The kinds a runtime takes, in the order Settings offers them.
    public static func kinds(for runtimeID: String) -> [CredentialKind] {
        allCases.filter { $0.runtimeID == runtimeID }
    }

    /// The variable the runtime reads it from. Only this one is set when it is lent; the
    /// runtime's others are taken out of the environment, so the one from Settings wins (D1).
    public var environmentVariable: String {
        switch self {
        case .oauthToken: "CLAUDE_CODE_OAUTH_TOKEN"
        case .apiKey: "ANTHROPIC_API_KEY"
        case .geminiAPIKey: "GEMINI_API_KEY"
        // Codex reads this one when told to sign in with a key (research T008).
        case .openAIAPIKey: "CODEX_API_KEY"
        }
    }

    /// Every variable its runtime might read a credential from: all of them go when one is
    /// lent. Gemini prefers `GOOGLE_API_KEY` to `GEMINI_API_KEY` when both are set.
    public var clearedVariables: [String] {
        switch self {
        case .oauthToken, .apiKey: ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"]
        case .geminiAPIKey: ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
        case .openAIAPIKey: ["CODEX_API_KEY", "OPENAI_API_KEY"]
        }
    }

    /// The variables a runtime's own sign-in might already be in.
    public static func variables(for runtimeID: String) -> [String] {
        Array(Set(kinds(for: runtimeID).flatMap(\.clearedVariables))).sorted()
    }

    /// Claude's, as 043 had them; kept for the server's own-sign-in check.
    public static let allVariables = variables(for: RuntimeCatalog.claude.id)

    /// Lent to this Mac's own agents as well as to servers (046, D3). Claude on the Mac uses
    /// the person's own sign-in; Gemini has no sign-in an individual can use but a key.
    public var isLentOnTheMac: Bool {
        switch self {
        case .oauthToken, .apiKey, .openAIAPIKey: false
        case .geminiAPIKey: true
        }
    }

    /// How Settings names it.
    public var display: String {
        switch self {
        case .oauthToken: "Subscription token"
        case .apiKey: "API key"
        case .geminiAPIKey: "Gemini API key"
        case .openAIAPIKey: "OpenAI API key"
        }
    }

    /// What Settings calls one when it cannot say which kind: "token" for Claude's two,
    /// "key" for the others.
    public static func noun(for runtimeID: String) -> String {
        runtimeID == RuntimeCatalog.claude.id ? "token" : "key"
    }

    /// Where to get one, under the paste field.
    public static func whereToGet(for runtimeID: String) -> String {
        switch runtimeID {
        case RuntimeCatalog.gemini.id:
            "Get one at aistudio.google.com/apikey. Gemini agents on this Mac use it too: Google’s own sign-in is closed to individuals."
        case RuntimeCatalog.codex.id:
            "Get one at platform.openai.com/api-keys. Servers use it only when this Mac has no ChatGPT sign-in to relay; Codex on this Mac uses ChatGPT."
        default:
            "Make one with `claude setup-token` on this Mac, or use an API key from console.anthropic.com."
        }
    }

    /// What is said when the pasted text is not one.
    public static func pasteRefusal(for runtimeID: String) -> String {
        switch runtimeID {
        case RuntimeCatalog.gemini.id: "That isn’t a Gemini API key. They start AIza or AQ."
        case RuntimeCatalog.codex.id: "That isn’t an OpenAI API key. They start sk-."
        default: "That isn’t a Claude token or API key. They start sk-ant-oat or sk-ant-api."
        }
    }

    var prefixes: [String] {
        switch self {
        case .oauthToken: ["sk-ant-oat"]
        case .apiKey: ["sk-ant-api"]
        case .geminiAPIKey: ["AIza", "AQ."]
        case .openAIAPIKey: ["sk-"]
        }
    }

    /// What a masked one starts with. A Gemini key's two shapes are not told apart once
    /// stored, so its mask starts with none of them.
    var maskPrefix: String {
        switch self {
        case .oauthToken, .apiKey: prefixes[0]
        case .geminiAPIKey, .openAIAPIKey: "key "
        }
    }
}

/// A credential's text, which only ever prints as its mask.
///
/// Not `Codable`, and its descriptions are the mask, so interpolating one into a log line,
/// an error or a crash annotation cannot write it out. `reveal()` is the one way to the
/// text, and is called where it is handed to the Keychain, a check, or a runtime.
public struct Secret: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let text: String
    public let kind: CredentialKind

    /// Nil for text that is not a credential of a kind the app knows.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let kind = CredentialKind(secret: trimmed),
              let prefix = kind.prefixes.first(where: { trimmed.hasPrefix($0) }),
              trimmed.count > prefix.count + 4 else { return nil }
        self.text = trimmed
        self.kind = kind
    }

    public func reveal() -> String { text }

    public var lastFour: String { String(text.suffix(4)) }

    /// `sk-ant-oat…a3f9`, or `key …a3f9` for Gemini's.
    public var mask: String { Self.mask(kind: kind, lastFour: lastFour) }

    public static func mask(kind: CredentialKind, lastFour: String) -> String {
        "\(kind.maskPrefix)…\(lastFour)"
    }

    public var description: String { mask }
    public var debugDescription: String { "Secret(\(mask))" }
    /// So `dump` and the debugger show the mask too, and not the stored text.
    public var customMirror: Mirror { Mirror(self, children: ["mask": mask]) }
}
