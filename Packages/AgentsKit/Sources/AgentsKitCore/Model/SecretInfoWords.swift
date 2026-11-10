import Foundation

/// What a secret's row tells you (#4159, `specs/secret-info/wireframe.md` sections 1, 2 and 4):
/// its last 4, when it was added, when it was last used, and that it is not backed up. The web
/// page's are the same, in `Web/src/model/secretInfo.ts`.
public enum SecretInfoWords {
    /// `••••ab12` at the end of the name line; `••••` when the row has no hint.
    public static func hint(_ hint: String?) -> String {
        "••••" + (hint ?? "")
    }

    /// "just now", "5 min ago", "2 h ago", "27 d ago".
    public static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3600)) h ago"
        default: return "\(Int(seconds / 86_400)) d ago"
        }
    }

    /// The date and time a hover gives: "12 Oct 2026, 09:14", where the reader is.
    public static func stamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_GB")
        format.timeZone = timeZone
        format.dateFormat = "d MMM yyyy, HH:mm"
        return format.string(from: date)
    }

    /// A part of the line, with what its hover gives.
    public struct Part: Sendable, Hashable {
        public var text: String
        public var help: String?
    }

    /// "Added 27 d ago", or "Replaced 2 d ago" after a Replace…, which keeps `created`. A row set
    /// before `created` was kept says "Set 3 d ago".
    public static func set(created: Date?, updated: Date?, now: Date = Date(), timeZone: TimeZone = .current) -> Part? {
        guard let updated = updated ?? created else { return nil }
        guard let created else {
            return Part(text: "Set \(age(updated, now: now))", help: "Set \(stamp(updated, timeZone: timeZone))")
        }
        if updated.timeIntervalSince(created) >= 1 {
            return Part(text: "Replaced \(age(updated, now: now))",
                        help: "Added \(stamp(created, timeZone: timeZone))\nReplaced \(stamp(updated, timeZone: timeZone))")
        }
        return Part(text: "Added \(age(created, now: now))", help: "Added \(stamp(created, timeZone: timeZone))")
    }

    /// "Used 2 h ago" after a read, "Never used" when none since it was added. The machines
    /// keep only the last operation (#4158), so a Replace… since the last read reads "Not used
    /// since it was replaced".
    public static func used(_ last: DaemonAPI.SecretLastOp?, now: Date = Date(), timeZone: TimeZone = .current) -> Part {
        guard let last else { return Part(text: "Never used") }
        let when = stamp(last.at, timeZone: timeZone)
        switch last.what {
        case "read": return Part(text: "Used \(age(last.at, now: now))", help: "Read \(when)")
        case "denied": return Part(text: "Use denied \(age(last.at, now: now))", help: "A use was denied \(when)")
        case "replaced": return Part(text: "Not used since it was replaced", help: "Replaced \(when)")
        default: return Part(text: "Never used")
        }
    }

    /// The line under a person's secret: "On 3 machines · Added 27 d ago · Used 2 h ago".
    public static func line(_ row: DaemonAPI.UserSecretRow, now: Date = Date(), timeZone: TimeZone = .current) -> [Part] {
        var parts = [Part(text: UserScopeWords.machines(row))]
        if let set = set(created: date(row.created), updated: date(row.updated), now: now, timeZone: timeZone) {
            parts.append(set)
        }
        parts.append(used(row.lastOp, now: now, timeZone: timeZone))
        return parts
    }

    /// The line under a secret for one session: "Fix the shop sign-in · Added 1 h ago · Used 20 min ago".
    public static func line(_ secret: SessionSecret, now: Date = Date(), timeZone: TimeZone = .current) -> [Part] {
        var parts = [Part(text: secret.title)]
        if let set = set(created: secret.created, updated: secret.setAt, now: now, timeZone: timeZone) {
            parts.append(set)
        }
        parts.append(used(secret.lastOp, now: now, timeZone: timeZone))
        return parts
    }

    /// The parts as one line, for a reader that has no hover.
    public static func joined(_ parts: [Part]) -> String {
        parts.map(\.text).joined(separator: " · ")
    }

    /// Under a person's secret that one copy only opens: "Only on devbox. Not backed up: if devbox
    /// is lost, this secret is lost." Nil while a machine waits for a copy (that line shows), and
    /// when the page says it once (`onlyMachine`).
    public static func notBackedUp(_ row: DaemonAPI.UserSecretRow, names: [String: String] = [:]) -> String? {
        guard row.backedUp == false, row.waiting?.isEmpty ?? true, let id = row.machines.first else { return nil }
        let name = names[id]
        return name.map { "Only on \($0). Not backed up: if \($0) is lost, this secret is lost." }
            ?? "Only on one machine. Not backed up: if it is lost, this secret is lost."
    }

    /// The one machine the person has, when every secret is on it and on no other: then the
    /// page says it once, at the top, and the rows have no warning.
    public static func onlyMachine(_ rows: [DaemonAPI.UserSecretRow]) -> String? {
        guard rows.contains(where: { $0.backedUp == false }) else { return nil }
        let all = Set(rows.flatMap { $0.machines + ($0.waiting ?? []) })
        return all.count == 1 ? all.first : nil
    }

    /// At the top of the page, for a person with one machine only.
    public static func onlyMachineLine(_ id: String, names: [String: String] = [:]) -> String {
        "Your secrets are only on \(names[id] ?? "one machine"). Add a second machine to keep a copy."
    }

    /// The control plane's machines' names, by id, for the warnings; the window's own Mac is
    /// "this Mac", as the design says it.
    public static func names(_ machines: [DaemonAPI.ControlMachine], thisMac: MachineRef? = nil) -> [String: String] {
        var names = Dictionary(machines.map { ($0.id.rawValue, $0.name) }, uniquingKeysWith: { first, _ in first })
        if let thisMac { names[thisMac.rawValue] = "this Mac" }
        return names
    }

    /// Under each secret for one session: it is on this Mac only.
    public static let sessionNotBackedUp = "Only on this Mac. Not backed up. It is deleted when the session is archived."

    /// A row's `created` or `updated`, as the control plane writes it (RFC 3339).
    static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: text) { return date }
        format.formatOptions = [.withInternetDateTime]
        return format.date(from: text)
    }
}
