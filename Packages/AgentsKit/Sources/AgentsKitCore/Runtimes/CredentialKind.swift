import Foundation

/// What sort of Claude credential a pasted string is (043, D1).
///
/// Told apart by prefix, because the two are handed to the runtime in different
/// environment variables and are checked with different headers. Anything else is refused
/// at paste, with a sentence, rather than saved and found wrong on a server later.
public enum CredentialKind: String, Codable, Hashable, Sendable {
    /// Made by `claude setup-token` for a subscription: `sk-ant-oat…`.
    case oauthToken
    /// From the Anthropic console: `sk-ant-api…`.
    case apiKey

    public init?(secret: String) {
        let text = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("sk-ant-oat") { self = .oauthToken }
        else if text.hasPrefix("sk-ant-api") { self = .apiKey }
        else { return nil }
    }

    /// The variable the runtime reads it from. Only this one is set when it is lent; the
    /// other is taken out of the environment, so the token from Settings wins (D1).
    public var environmentVariable: String {
        switch self {
        case .oauthToken: "CLAUDE_CODE_OAUTH_TOKEN"
        case .apiKey: "ANTHROPIC_API_KEY"
        }
    }

    public static let allVariables = ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"]

    /// How Settings names it.
    public var display: String {
        switch self {
        case .oauthToken: "Subscription token"
        case .apiKey: "API key"
        }
    }

    var prefix: String {
        switch self {
        case .oauthToken: "sk-ant-oat"
        case .apiKey: "sk-ant-api"
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

    /// Nil for text that is not a Claude credential.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let kind = CredentialKind(secret: trimmed), trimmed.count > kind.prefix.count + 4 else { return nil }
        self.text = trimmed
        self.kind = kind
    }

    public func reveal() -> String { text }

    public var lastFour: String { String(text.suffix(4)) }

    /// `sk-ant-oat…a3f9`.
    public var mask: String { Self.mask(kind: kind, lastFour: lastFour) }

    public static func mask(kind: CredentialKind, lastFour: String) -> String {
        "\(kind.prefix)…\(lastFour)"
    }

    public var description: String { mask }
    public var debugDescription: String { "Secret(\(mask))" }
    /// So `dump` and the debugger show the mask too, and not the stored text.
    public var customMirror: Mirror { Mirror(self, children: ["mask": mask]) }
}
