import Foundation

/// What sort of credential a pasted string is (043, D1; Gemini's, 046). Claude and Codex have
/// none: a server's Claude and Codex sign in through this Mac's own sign-ins, relayed (047
/// R12, 056).
///
/// Told apart by prefix, because each is handed to its runtime in its own environment
/// variable and checked with its own request. Anything else is refused at paste, with a
/// sentence, rather than saved and found wrong on a server later.
public enum CredentialKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// From Google AI Studio (046): `AIza…`, or `AQ.…` for the keys it issues now. The only
    /// way into Gemini CLI for an individual since Google closed its own sign-in to them.
    case geminiAPIKey

    public init?(secret: String) {
        let text = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let kind = Self.allCases.first(where: { kind in kind.prefixes.contains { text.hasPrefix($0) } })
        else { return nil }
        self = kind
    }

    /// The runtime it signs in.
    public var runtimeID: String {
        switch self {
        case .geminiAPIKey: RuntimeCatalog.gemini.id
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
        case .geminiAPIKey: "GEMINI_API_KEY"
        }
    }

    /// Every variable its runtime might read a credential from: all of them go when one is
    /// lent. Gemini prefers `GOOGLE_API_KEY` to `GEMINI_API_KEY` when both are set.
    public var clearedVariables: [String] {
        switch self {
        case .geminiAPIKey: ["GEMINI_API_KEY", "GOOGLE_API_KEY"]
        }
    }

    /// The variables a runtime's own sign-in might already be in.
    public static func variables(for runtimeID: String) -> [String] {
        Array(Set(kinds(for: runtimeID).flatMap(\.clearedVariables))).sorted()
    }

    /// Lent to this Mac's own agents as well as to servers (046, D3): Gemini has no sign-in
    /// an individual can use but a key.
    public var isLentOnTheMac: Bool {
        switch self {
        case .geminiAPIKey: true
        }
    }

    /// How Settings names it.
    public var display: String {
        switch self {
        case .geminiAPIKey: "Gemini API key"
        }
    }

    /// What Settings calls one when it cannot say which kind.
    public static func noun(for runtimeID: String) -> String { "key" }

    /// Where to get one, under the paste field.
    public static func whereToGet(for runtimeID: String) -> String {
        source(for: runtimeID) + " Gemini agents on this Mac use it too: Google’s own sign-in is closed to individuals."
    }

    /// Where to get one, and no more: under the paste field of a client that keeps none,
    /// the Remote and the page (#344).
    public static func source(for runtimeID: String) -> String {
        "Get one at aistudio.google.com/apikey."
    }

    /// What is said when the pasted text is not one.
    public static func pasteRefusal(for runtimeID: String) -> String {
        "That isn’t a Gemini API key. They start AIza or AQ."
    }

    var prefixes: [String] {
        switch self {
        case .geminiAPIKey: ["AIza", "AQ."]
        }
    }

    /// What a masked one starts with. A Gemini key's two shapes are not told apart once
    /// stored, so its mask starts with none of them.
    var maskPrefix: String {
        switch self {
        case .geminiAPIKey: "key "
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

    /// `key …a3f9`.
    public var mask: String { Self.mask(kind: kind, lastFour: lastFour) }

    public static func mask(kind: CredentialKind, lastFour: String) -> String {
        "\(kind.maskPrefix)…\(lastFour)"
    }

    public var description: String { mask }
    public var debugDescription: String { "Secret(\(mask))" }
    /// So `dump` and the debugger show the mask too, and not the stored text.
    public var customMirror: Mirror { Mirror(self, children: ["mask": mask]) }
}
