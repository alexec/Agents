import Foundation

/// What agents call the person, and how they refer to them (#121).
///
/// Kept by the Mac's daemon and copied to every server, the way the permission modes are,
/// so an agent on a server calls the person what one on the Mac does rather than by
/// that server's account name. Paired devices reach the Mac's, so they need no copy.
public struct PersonSettings: Codable, Sendable, Hashable {
    /// What the person asked to be called. Nil or blank: the Mac account's first name.
    public var name: String?
    /// The pronouns they gave, as they wrote them ("she/her"). Nil or blank: none given,
    /// and agents use the name or "they".
    public var pronouns: String?

    public init(name: String? = nil, pronouns: String? = nil) {
        self.name = name
        self.pronouns = pronouns
    }

    /// The name agents are told: the one set, or the first word of the account's full
    /// name, or "the person" where the account has none.
    public func effectiveName(accountName: String = NSFullUserName()) -> String {
        if let name = Self.trimmed(name) { return name }
        return Self.firstName(of: accountName) ?? "the person"
    }

    /// The pronouns given, trimmed; nil where none were.
    public var givenPronouns: String? { Self.trimmed(pronouns) }

    /// The same settings with the name filled in, for a server whose own account name
    /// is not the person's.
    public func resolved(accountName: String = NSFullUserName()) -> PersonSettings {
        PersonSettings(name: effectiveName(accountName: accountName), pronouns: givenPronouns)
    }

    /// "Alex Collins" → "Alex".
    public static func firstName(of fullName: String) -> String? {
        fullName.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
