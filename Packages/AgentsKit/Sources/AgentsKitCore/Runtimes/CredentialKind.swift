import Foundation

/// What sort of credential a pasted string is (043, D1). Claude and Codex have none: a
/// server's Claude and Codex sign in through this Mac's own sign-ins, relayed (047 R12,
/// 056). No runtime takes one from Settings now that Gemini is retired (#3043); the type
/// stays for `PoolEntry.credentialKind` (052), which keeps a kind's raw value even when
/// Settings offers none.
///
/// Told apart by prefix, because each is handed to its runtime in its own environment
/// variable and checked with its own request. Anything else is refused at paste, with a
/// sentence, rather than saved and found wrong on a server later.
public enum CredentialKind: Hashable, Sendable, CaseIterable {
    /// No case for any prefix to match, since there is no case at all.
    public init?(secret: String) { nil }

    /// The runtime it signs in.
    public var runtimeID: String {
        switch self {}
    }

    /// The kinds a runtime takes, in the order Settings offers them. No case takes any.
    public static func kinds(for runtimeID: String) -> [CredentialKind] { [] }

    /// The variable the runtime reads it from. Only this one is set when it is lent; the
    /// runtime's others are taken out of the environment, so the one from Settings wins (D1).
    public var environmentVariable: String {
        switch self {}
    }

    /// Every variable its runtime might read a credential from: all of them go when one is
    /// lent.
    public var clearedVariables: [String] {
        switch self {}
    }

    /// The variables a runtime's own sign-in might already be in. No kind clears any.
    public static func variables(for runtimeID: String) -> [String] { [] }

    /// Lent to this Mac's own agents as well as to servers (046, D3).
    public var isLentOnTheMac: Bool {
        switch self {}
    }

    /// How Settings names it.
    public var display: String {
        switch self {}
    }

    /// What Settings calls one when it cannot say which kind.
    public static func noun(for runtimeID: String) -> String { "key" }

    /// Where to get one, under the paste field.
    public static func whereToGet(for runtimeID: String) -> String {
        source(for: runtimeID)
    }

    /// Where to get one, and no more: under the paste field of a client that keeps none,
    /// the Remote and the page (#344).
    public static func source(for runtimeID: String) -> String { "" }

    /// What is said when the pasted text is not one.
    public static func pasteRefusal(for runtimeID: String) -> String { "That isn’t a key \(noun(for: runtimeID)) this app knows." }

    var prefixes: [String] {
        switch self {}
    }

    /// What a masked one starts with.
    var maskPrefix: String {
        switch self {}
    }
}

/// Hand-written, because an empty enum cannot declare a raw type (so Swift cannot
/// synthesize either this or `Codable` for one): every string is a kind this build does
/// not have, matching `init?(rawValue:)`'s usual meaning for a case that does not exist.
extension CredentialKind: RawRepresentable {
    public typealias RawValue = String

    public init?(rawValue: String) { nil }

    public var rawValue: String {
        switch self {}
    }
}

/// Hand-written for the same reason: `encode` never runs, since nothing is ever a
/// `CredentialKind`, and `init(from:)` always refuses, as `init?(rawValue:)` does.
extension CredentialKind: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        throw DecodingError.dataCorruptedError(in: container,
                                               debugDescription: "\(text) is not a credential kind this build knows.")
    }

    public func encode(to encoder: Encoder) throws {
        switch self {}
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

    /// Whether this is a kind `runtimeID` takes. No case to be one of, since nothing is
    /// ever a `Secret`.
    public func isFor(_ runtimeID: String) -> Bool {
        switch kind {}
    }

    /// `key …a3f9`. No case to read a prefix from, since nothing is ever a `Secret`.
    public var mask: String {
        switch kind {}
    }

    public var description: String { mask }
    public var debugDescription: String { "Secret(\(mask))" }
    /// So `dump` and the debugger show the mask too, and not the stored text.
    public var customMirror: Mirror { Mirror(self, children: ["mask": mask]) }
}
