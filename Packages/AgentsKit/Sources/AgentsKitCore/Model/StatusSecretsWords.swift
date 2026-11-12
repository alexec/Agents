import Foundation

/// Status ▸ Secrets and Status ▸ Accounts (#4161, specs/secret-info §9): what happened last to each of
/// the person's secrets and outside accounts, newest first, with a time ago. Status only: a press
/// opens the item in Settings ▸ You. The window and the Remote draw it from `Shared/UI`; the web page
/// says the same in `Web/src/model/statusSecrets.ts`.
public enum StatusSecretsWords {
    public static let secretsTitle = "Secrets"
    public static let accountsTitle = "Accounts"
    public static let secretsLead = "What happened to your secrets last, newest first. Only status here: "
        + "change them in Settings ▸ You ▸ Secrets."
    public static let accountsLead = "What happened to your accounts last, newest first. Only status here: "
        + "change them in Settings ▸ You ▸ Accounts."
    public static let editSecrets = "Edit in Settings ▸ You ▸ Secrets"
    public static let editAccounts = "Edit in Settings ▸ You ▸ Accounts"
    public static let noSecrets = "No secrets yet."
    public static let noAccounts = "No accounts yet."
    /// Before the grey line's name, for VoiceOver.
    public static let readLabel = "Last read:"
    public static let notBackedUp = "Not backed up: only on one machine."
    public static let secretsHelp = "When something last happened to one of your secrets"
    public static let accountsHelp = "When something last happened to one of your outside accounts"

    /// One line of a Status list: an item, its last operation in words, when, and whether it is backed up.
    public struct Line: Identifiable, Hashable, Sendable {
        public var id: String
        /// The secret's name, or the account's service.
        public var title: String
        /// The account's address; nil for a secret.
        public var detail: String?
        /// `••••ab12`, `••••`, or for an account with no secret "no secret".
        public var hint: String
        /// "Read", "Replaced", "GITLAB_TOKEN read"; nil when nothing is known.
        public var operation: String?
        public var at: Date?
        public var backedUp: Bool
        /// Whether the last operation was a read: of the secret, or of the secret or card the account names.
        public var isRead: Bool = false
        /// The session that did the last operation, when one did.
        public var agent: UUID?
    }

    /// How long a read stays recent for the sidebar row's grey line.
    public static let recentReadWindow: TimeInterval = 4 * 3600

    /// `••••` and the last 4 when a machine sent them (#4158).
    public static func masked(_ hint: String?) -> String {
        "••••" + (hint ?? "")
    }

    /// A secret's operation in words.
    public static func secretOperation(_ what: String) -> String {
        switch what {
        case "read": "Read"
        case "denied": "Denied"
        case "added": "Added"
        case "replaced": "Replaced"
        case "removed": "Removed"
        default: what.prefix(1).uppercased() + what.dropFirst()
        }
    }

    /// An account's own operation in words.
    public static func accountOperation(_ what: String) -> String {
        switch what {
        case "read": "Read"
        case "added": "Added"
        case "edited": "Edited"
        default: what.prefix(1).uppercased() + what.dropFirst()
        }
    }

    /// The person's secrets, newest operation first. A secret with no operation yet goes by when it
    /// was added, and those with no time at all go last, by name.
    public static func secretLines(_ rows: [DaemonAPI.UserSecretRow]) -> [Line] {
        rows.map { row in
            let added = row.created.flatMap(parseDate)
            return Line(id: row.name, title: row.name, detail: nil, hint: masked(row.hint),
                        operation: row.lastOp.map { secretOperation($0.what) } ?? (added == nil ? nil : "Added"),
                        at: row.lastOp?.at ?? added, backedUp: row.backedUp != false,
                        isRead: row.lastOp?.what == "read", agent: row.lastOp?.agent)
        }
        .sorted(by: newestFirst)
    }

    /// The person's accounts, newest operation first. An account's newest operation is the newest of
    /// its own (made, edited, or one a machine sent) and the last operation of the secret and card it
    /// names, which says which (#4157): "GITLAB_TOKEN read". It is backed up when they are.
    public static func accountLines(_ accounts: [DaemonAPI.OutsideAccount], secrets: [DaemonAPI.UserSecretRow]) -> [Line] {
        let byName = Dictionary(secrets.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return accounts.map { account in
            var newest: (words: String, at: Date, read: Bool, agent: UUID?)?
            func consider(_ words: String, _ at: Date?, read: Bool = false, agent: UUID? = nil) {
                guard let at, newest.map({ at > $0.at }) ?? true else { return }
                newest = (words, at, read, agent)
            }
            consider("Added", account.made.flatMap(parseDate))
            consider("Edited", account.edited)
            if let op = account.lastOp { consider(accountOperation(op.what), op.at, read: op.what == "read", agent: op.agent) }
            let named = [account.secret, account.card].compactMap { $0 }.filter { !$0.isEmpty }
            for name in named {
                if let op = byName[name]?.lastOp { consider("\(name) \(secretOperation(op.what).lowercased())", op.at, read: op.what == "read", agent: op.agent) }
            }
            let secret = account.secret.flatMap { $0.isEmpty ? nil : $0 }
            let hint = secret.map { byName[$0].map { masked($0.hint) } ?? "not in Secrets" } ?? "no secret"
            let backedUp = named.allSatisfy { byName[$0]?.backedUp != false }
            return Line(id: account.id, title: account.service, detail: account.address, hint: hint,
                        operation: newest?.words, at: newest?.at, backedUp: backedUp, isRead: newest?.read ?? false,
                        agent: newest?.agent)
        }
        .sorted(by: newestFirst)
    }

    /// The sidebar row's time: the newest operation on any line.
    public static func newest(_ lines: [Line]) -> Date? {
        lines.compactMap(\.at).max()
    }

    /// The sidebar row's grey line: the name of the item read last (an account's address too) and the session that
    /// read it, by `agentTitle`, only when the newest operation on any line is a read in the last 4 hours. Nil otherwise.
    /// A session the client does not know, or one with no title, is left out.
    public static func recentRead(_ lines: [Line], now: Date = Date(), agentTitle: (UUID) -> String? = { _ in nil }) -> String? {
        guard let newest = lines.filter({ $0.at != nil }).max(by: { $0.at! < $1.at! }),
              newest.isRead, let at = newest.at, now.timeIntervalSince(at) < recentReadWindow else { return nil }
        let agent = newest.agent.flatMap(agentTitle)
        return [newest.title, newest.detail, agent].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "5 min ago", "2 h ago", "3 d ago", as the wireframe's rows.
    public static func ago(_ at: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(at))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3600)) h ago"
        default: return "\(Int(seconds / 86_400)) d ago"
        }
    }

    /// A row's line under its name: the hint, then the operation.
    public static func summary(_ line: Line) -> String {
        [line.detail, line.hint, line.operation].compactMap { $0 }.joined(separator: " · ")
    }

    private static func newestFirst(_ a: Line, _ b: Line) -> Bool {
        switch (a.at, b.at) {
        case let (x?, y?) where x != y: x > y
        case (.some, nil): true
        case (nil, .some): false
        default: a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    /// An RFC 3339 time, with or without its fraction, or a day (`made` is YYYY-MM-DD).
    static func parseDate(_ text: String) -> Date? {
        let whole = ISO8601DateFormatter()
        if let date = whole.date(from: text) { return date }
        let fraction = ISO8601DateFormatter()
        fraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fraction.date(from: text) { return date }
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return day.date(from: text)
    }
}
