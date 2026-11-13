#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

/// Reveal and Copy of a person's own secret (#5112,
/// `specs/5112-view-copy-secrets-accounts/wireframes.md`): the client asks the control plane
/// for its own sealed copy (`user/sealedSecret`, which writes the audit entry first), opens it
/// with its own key, shows or copies the value, and forgets it. The web page's
/// `Web/src/model/reveal.ts` has the same words.
public enum SecretRevealWords {
    // The times and the words are Settings ▸ You ▸ Secrets' (#5115), so both panes say the same.
    public static let shownSeconds = UserScopeWords.shownSeconds
    public static let clipboardSeconds = UserScopeWords.clipboardSeconds
    public static let copiedSeconds = UserScopeWords.copiedSeconds

    public static let shown = "Shown for 30 s. Your reveal is in the audit log."
    public static let copied = UserScopeWords.copied()
    /// A copy of a plain field, which is not audited and not cleared.
    public static let copiedPlain = "Copied."
    public static let noCopy = UserScopeWords.noCopyYet
    public static let didNotOpen = UserScopeWords.didNotOpen
    public static let notCard = "This secret is not a card."

    /// What went wrong, in one line for the row (section 6).
    public static func failure(_ error: any Error) -> String {
        if let error = error as? JSONRPCError {
            switch error.code {
            case DaemonAPI.Failure.noClientCopy: return noCopy
            case JSONRPCError.methodNotFound: return UserScopeWords.revealNeedsNewerPlane
            default: return error.message
            }
        }
        if error is RevealFailure { return didNotOpen }
        return "The control plane can’t be reached."
    }

    /// The copy did not open with this client's key (a changed key).
    public struct RevealFailure: Error {
        public init() {}
    }
}

public extension CardSecret {
    /// One part of a card, as the reveal shows it (section 4).
    struct Shown: Hashable, Sendable, Identifiable {
        public var part: DaemonAPI.UserSealedSecretRequest.Part
        public var label: String
        /// As shown: the number in groups of four.
        public var text: String
        /// As copied: the number's digits only.
        public var value: String
        public var id: DaemonAPI.UserSealedSecretRequest.Part { part }
    }

    /// The five parts, in the order a payment form asks for them.
    var shown: [Shown] {
        UserScopeWords.cardParts.map { part in
            let value = self.part(part)
            let text = part == .number
                ? stride(from: 0, to: value.count, by: 4).map { String(value.dropFirst($0).prefix(4)) }.joined(separator: " ")
                : value
            return Shown(part: part, label: UserScopeWords.partLabel(part), text: text, value: value)
        }
    }
}

#if canImport(CryptoKit)
public extension ClientSealing {
    /// Asks the control plane for this client's own copy of one secret (it writes the audit
    /// entry first), and opens it here.
    static func reveal(_ request: DaemonAPI.UserSealedSecretRequest, on control: DaemonClient, key: DeviceKey,
                       client: UUID) async throws -> String {
        let to = try await control.call(DaemonAPI.Method.userSecretRecipients, DaemonAPI.Empty(),
                                        returning: DaemonAPI.SealRecipients.self)
        let sealed = try await control.call(DaemonAPI.Method.userSealedSecret, request, returning: DaemonAPI.UserSealedSecret.self)
        // A copy that does not open here (a changed key) has its own line.
        do {
            return try open(sealed, user: to.user ?? "", with: key, client: client)
        } catch {
            throw SecretRevealWords.RevealFailure()
        }
    }
}
#endif

/// Settings ▸ You ▸ Accounts ▸ Details… (#5116, wireframes section 7): each field, and which
/// ones Copy.
public extension AccountsWords {
    static let details = "Details…"
    static let noSecretLine = "No secret. Add one in Secrets, then name it in Edit…."
    static let notInSecrets = "not in Secrets"

    /// One line of the sheet.
    struct Field: Hashable, Sendable, Identifiable {
        public var label: String
        public var text: String
        /// Copy copies `text`. Never a secret: a plain copy is not audited.
        public var copies: Bool
        public var id: String { label }
    }

    /// What an account names for its secret or its card.
    enum Named: Hashable, Sendable {
        /// It names none.
        case none
        /// A name Secrets does not have, such as "1Password": the text, and Copy for it.
        case elsewhere(String)
        /// A secret in Secrets: Reveal and Copy fetch this client's own copy.
        case secret(DaemonAPI.UserSecretRow)
    }

    static func named(_ name: String?, rows: [DaemonAPI.UserSecretRow]) -> Named {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return .none }
        return rows.first { $0.name == name }.map(Named.secret) ?? .elsewhere(name)
    }

    /// The first part: who and what it is.
    static func identity(_ a: DaemonAPI.OutsideAccount) -> [Field] {
        var out = [Field(label: "Service", text: a.service, copies: true)]
        if let v = text(a.address) { out.append(Field(label: "Address", text: v, copies: true)) }
        if let v = text(a.username) { out.append(Field(label: "User name", text: v, copies: true)) }
        out.append(Field(label: "Description", text: about(a), copies: false))
        let plan = [text(a.plan), a.monthlyCostUsd.map { "\(money($0)) a month" }].compactMap { $0 }.joined(separator: " · ")
        if !plan.isEmpty { out.append(Field(label: "Plan", text: plan, copies: false)) }
        out.append(Field(label: "Two-factor", text: text(a.twoFactor) ?? "None", copies: false))
        return out
    }

    /// "2027-02-01 (in 81 d)", or nil when it has no date.
    static func tokenExpiry(_ a: DaemonAPI.OutsideAccount, now: Date = Date()) -> String? {
        guard let day = text(a.tokenExpires) else { return nil }
        guard let at = dayFormatter.date(from: day) else { return day }
        let days = Int((at.timeIntervalSince(now) / 86_400).rounded(.up))
        return days < 0 ? "\(day) (expired)" : "\(day) (in \(days) d)"
    }

    /// The last part: notes, the issue and the projects.
    static func record(_ a: DaemonAPI.OutsideAccount) -> [Field] {
        var out: [Field] = []
        if let v = text(a.notes) { out.append(Field(label: "Notes", text: v, copies: true)) }
        if let v = text(a.issue) { out.append(Field(label: "Issue", text: v, copies: false)) }
        let projects = (a.projects ?? []).joined(separator: ", ")
        out.append(Field(label: "Projects", text: projects.isEmpty ? "All" : projects, copies: false))
        return out
    }

    /// The account it was opened from, for the audit entry.
    static func auditAccount(_ a: DaemonAPI.OutsideAccount) -> DaemonAPI.UserSealedSecretRequest.Account {
        .init(service: a.service, address: text(a.address))
    }

    private static func text(_ s: String?) -> String? {
        let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
