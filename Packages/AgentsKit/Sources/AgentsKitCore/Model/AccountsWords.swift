import Foundation

/// The words and sums of Settings ▸ You ▸ Accounts (#3967), as the web page's `model/accounts.ts`.
public enum AccountsWords {
    public static let title = "Accounts"
    public static let noSecrets = "No secret goes here: give a card or a token by its name in Secrets."
    /// In place of the pane when the control plane does not have it (#4190), as the web page's.
    public static let planeNeedsUpdate = "The control plane needs an update to do this."

    /// What the pane says in place of Accounts (#4190, #4100): the control plane takes the
    /// accounts part of `user/setSettings` only from `user/3`, so an older one, which refuses it,
    /// is sent nothing. Nil when it has it, and while its `control/status` has not come yet.
    public static func refusal(_ status: DaemonAPI.ControlStatus?) -> String? {
        guard let status else { return nil }
        return status.capabilities?.contains(Capability.user3) == true ? nil : planeNeedsUpdate
    }

    /// The accounts a project uses: those that name it and those that name none.
    public static func of(_ all: [DaemonAPI.OutsideAccount], project: String) -> [DaemonAPI.OutsideAccount] {
        guard !project.isEmpty else { return all }
        return all.filter { a in
            let named = a.projects ?? []
            return named.isEmpty || named.contains { $0.caseInsensitiveCompare(project) == .orderedSame }
        }
    }

    /// Every project an account names, once, in order.
    public static func projects(_ all: [DaemonAPI.OutsideAccount]) -> [String] {
        var seen = Set<String>()
        return all.flatMap { $0.projects ?? [] }.filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public static func money(_ usd: Double) -> String {
        usd == usd.rounded() ? "$\(Int(usd))" : String(format: "$%.2f", usd)
    }

    public static func cost(_ a: DaemonAPI.OutsideAccount) -> String {
        a.monthlyCostUsd.map { "\(money($0))/month" } ?? ""
    }

    /// The description (#4164), under the address; an account made before it has none.
    public static func about(_ a: DaemonAPI.OutsideAccount) -> String {
        let text = (a.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? noDescription : text
    }

    public static let noDescription = "No description"

    /// Ask before use (#4163): nil is on, as agentsd reads it.
    public static func asks(_ a: DaemonAPI.OutsideAccount) -> Bool { a.askBeforeUse != false }

    /// Under the sheet's Ask before use toggle. The toggle and the row's mark are `AskBeforeUseWords`'.
    public static func askHint(_ isOn: Bool) -> String {
        isOn ? "An agent's read of it waits for your approval: Approve, Approve for This Session, Always Approve or Deny."
            : "Every agent can read it with no approval."
    }

    /// The sheet's field for Ask before use: "off" when it is off, else none.
    public static let askField = "askBeforeUse"

    /// The address and the plan, under the service.
    public static func detail(_ a: DaemonAPI.OutsideAccount) -> String {
        [a.address, a.plan].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The foot: how many, and what they cost a month together.
    public static func foot(_ shown: [DaemonAPI.OutsideAccount]) -> String {
        let total = shown.compactMap(\.monthlyCostUsd).reduce(0, +)
        return "\(shown.count) \(shown.count == 1 ? "account" : "accounts"), \(money(total)) a month."
    }

    /// A line when the token expires in 30 days or less, or has expired.
    public static func expiresSoon(_ a: DaemonAPI.OutsideAccount, now: Date) -> String? {
        guard let day = a.tokenExpires, let at = dayFormat.date(from: day) else { return nil }
        let days = Int((at.timeIntervalSince(now) / 86_400).rounded(.up))
        if days < 0 { return "Its token expired on \(day)." }
        return days <= 30 ? "Its token expires on \(day)." : nil
    }

    /// The secret an account names (#4160): its token, else its card.
    public static func secretName(_ a: DaemonAPI.OutsideAccount) -> String? {
        [a.secret, a.card].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// At the end of the first line (#4160): the last 4 of the secret it names, as its row in
    /// Secrets has them; "no secret" when it names none; "not in Secrets" when Secrets has no
    /// such name (a secret kept somewhere else).
    public static func hint(_ a: DaemonAPI.OutsideAccount, rows: [DaemonAPI.UserSecretRow]) -> String {
        guard let name = secretName(a) else { return "no secret" }
        guard let row = rows.first(where: { $0.name == name }) else { return "not in Secrets" }
        return SecretInfoWords.hint(row.hint)
    }

    /// The line under an account (#4160): "Made 9 d ago · Edited 1 d ago · Used 2 h ago", and
    /// "Token expires in 45 d" while that is more than 30 days away (nearer, its own line says it).
    public static func line(_ a: DaemonAPI.OutsideAccount, now: Date = Date(), timeZone: TimeZone = .current) -> [SecretInfoWords.Part] {
        var parts: [SecretInfoWords.Part] = []
        if let made = a.made, let day = dayFormat.date(from: made) {
            let days = Int(now.timeIntervalSince(day) / 86_400)
            parts.append(.init(text: days < 1 ? "Made today" : "Made \(days) d ago", help: "Made \(made)"))
        }
        if let edited = a.edited {
            parts.append(.init(text: "Edited \(SecretInfoWords.age(edited, now: now))",
                               help: "Edited \(SecretInfoWords.stamp(edited, timeZone: timeZone))"))
        }
        parts.append(used(a.lastOp, now: now, timeZone: timeZone))
        if let day = a.tokenExpires, let at = dayFormat.date(from: day) {
            let days = Int((at.timeIntervalSince(now) / 86_400).rounded(.up))
            if days > 30 { parts.append(.init(text: "Token expires in \(days) d", help: "Its token expires on \(day)")) }
        }
        return parts
    }

    /// "Used 2 h ago": an agent's manage_accounts call that names it, or a read of its secret or
    /// card, whichever is newer; "Never used" for none.
    public static func used(_ last: DaemonAPI.AccountLastOp?, now: Date = Date(), timeZone: TimeZone = .current) -> SecretInfoWords.Part {
        guard let last else { return .init(text: "Never used") }
        let when = SecretInfoWords.stamp(last.at, timeZone: timeZone)
        let help = switch last.what {
        case "added": "Added by an agent \(when)"
        case "edited": "Changed by an agent \(when)"
        default: "Read \(when)"
        }
        return .init(text: "Used \(SecretInfoWords.age(last.at, now: now))", help: help)
    }

    /// Under an account whose key or card one copy only opens (#4160): "Its key, AWS_SECRET_KEY,
    /// is only on devbox. Not backed up." Nil while a machine waits for a copy.
    public static func notBackedUp(_ a: DaemonAPI.OutsideAccount, rows: [DaemonAPI.UserSecretRow],
                                   names: [String: String] = [:]) -> String? {
        for (kind, name) in [("key", a.secret), ("card", a.card)] {
            guard let name = name?.trimmingCharacters(in: .whitespaces), let row = rows.first(where: { $0.name == name }),
                  row.backedUp == false, row.waiting?.isEmpty ?? true, let id = row.machines.first else { continue }
            return "Its \(kind), \(name), is only on \(names[id] ?? "one machine"). Not backed up."
        }
        return nil
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The sheet's fields of an account.
    public static func fields(_ a: DaemonAPI.OutsideAccount) -> [String: String] {
        var f: [String: String] = ["service": a.service]
        f["description"] = a.description
        f["address"] = a.address
        f["plan"] = a.plan
        f["cost"] = a.monthlyCostUsd.map { $0 == $0.rounded() ? String(Int($0)) : String($0) }
        f["card"] = a.card
        f["secret"] = a.secret
        f["twoFactor"] = a.twoFactor
        f["issue"] = a.issue
        f["made"] = a.made
        f["tokenExpires"] = a.tokenExpires
        f["notes"] = a.notes
        f["projects"] = a.projects?.joined(separator: ", ")
        f[askField] = asks(a) ? nil : "off"
        return f
    }

    /// The account the sheet's fields say; an empty field is no value.
    public static func account(_ f: [String: String]) -> DaemonAPI.OutsideAccount {
        func v(_ key: String) -> String? {
            let t = (f[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let projects = (v("projects") ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return DaemonAPI.OutsideAccount(service: v("service") ?? "", description: v("description"), address: v("address"), plan: v("plan"),
                                        monthlyCostUsd: v("cost").flatMap { Double($0.replacingOccurrences(of: "$", with: "")) },
                                        card: v("card"), secret: v("secret"), twoFactor: v("twoFactor"), issue: v("issue"),
                                        made: v("made"), tokenExpires: v("tokenExpires"), notes: v("notes"),
                                        projects: projects.isEmpty ? nil : projects, askBeforeUse: f[askField] == "off" ? false : nil)
    }
}
