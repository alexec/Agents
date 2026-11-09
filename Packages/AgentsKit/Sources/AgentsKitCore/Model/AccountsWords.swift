import Foundation

/// The words and sums of Settings ▸ You ▸ Accounts (#3967), as the web page's `model/accounts.ts`.
public enum AccountsWords {
    public static let title = "Accounts"
    public static let noSecrets = "No secret goes here: give a card or a token by its name in Secrets."

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
        isOn ? "An agent's read of it waits for your approval: Allow Once, for This Session, Always or Deny."
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
