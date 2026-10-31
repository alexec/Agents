import Foundation

/// Who did what (#996, spec 736 US8): the control plane's audit, beside the Events page.
///
/// The control plane writes each entry with the actor it knows the client by, never one a
/// client names. Until people (#994) are built, every actor is the local owner and the
/// client they used.
public extension DaemonAPI {
    /// The event that started a bot's action.
    struct AuditCause: Codable, Sendable, Hashable {
        public var kind: String
        public var id: String
    }

    /// A person and their client, or a bot and the event that started it.
    struct AuditActor: Codable, Sendable, Hashable {
        public var user: String
        public var userName: String?
        public var client: UUID?
        public var clientName: String?
        public var event: AuditCause?

        public init(user: String, userName: String? = nil, client: UUID? = nil, clientName: String? = nil,
                    event: AuditCause? = nil) {
            self.user = user
            self.userName = userName
            self.client = client
            self.clientName = clientName
            self.event = event
        }
    }

    /// One entry: who, what in words, the call it came from, on which machine, and when.
    struct AuditEntry: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var at: Date
        public var action: String
        public var method: String
        public var host: MachineRef?
        public var target: String?
        public var actor: AuditActor

        public init(id: String, at: Date, action: String, method: String, host: MachineRef? = nil, target: String? = nil,
                    actor: AuditActor) {
            self.id = id
            self.at = at
            self.action = action
            self.method = method
            self.host = host
            self.target = target
            self.actor = actor
        }
    }

    /// `audit/list` and `audit/export`: a range and, for an admin, one person.
    struct AuditQuery: Codable, Sendable, Hashable {
        public var since: Date?
        public var until: Date?
        public var user: String?
        public var limit: Int?

        public init(since: Date? = nil, until: Date? = nil, user: String? = nil, limit: Int? = nil) {
            self.since = since
            self.until = until
            self.user = user
            self.limit = limit
        }
    }

    /// `audit/list`'s answer: newest first, the days kept, and whether older ones were left out.
    struct AuditList: Codable, Sendable, Hashable {
        public var entries: [AuditEntry]
        public var days: Int
        public var more: Bool
        public var admin: Bool
    }

    /// `audit/export`'s answer: JSON lines, oldest first.
    struct AuditExport: Codable, Sendable, Hashable {
        public var lines: String
        public var count: Int
    }

    /// `control/setAuditDays`.
    struct AuditDays: Codable, Sendable, Hashable {
        public var days: Int

        public init(days: Int) { self.days = days }
    }
}

public extension DaemonAPI.Method {
    /// `AuditQuery` → `AuditList` (#996).
    static let auditList = "audit/list"
    /// `AuditQuery` → `AuditExport`, an admin's only (#996).
    static let auditExport = "audit/export"
    /// `AuditDays` → `AuditDays`, an admin's only (#996).
    static let controlSetAuditDays = "control/setAuditDays"
}

/// The words an audit entry is shown in, the same on the Mac and the Remote (the web
/// page's are `Web/src/model/audit.ts`).
public enum AuditWords {
    /// The choices for how long entries are kept.
    public static let dayChoices = [30, 90, 180, 365]

    /// "Local owner · MacBook Pro": the person, then the client they used; a bot's names
    /// the event that started it.
    public static func who(_ actor: DaemonAPI.AuditActor) -> String {
        var parts = [actor.userName ?? "Someone"]
        if let client = actor.clientName, !client.isEmpty {
            parts.append(client)
        }
        if let event = actor.event {
            parts.append("for \(event.kind)")
        }
        return parts.joined(separator: " · ")
    }

    /// "on box-1", or "on the control plane" for its own methods.
    public static func place(_ entry: DaemonAPI.AuditEntry, hostName: (MachineRef) -> String) -> String {
        entry.host.map { "on \(hostName($0))" } ?? "on the control plane"
    }

    /// The call, and what it acted on: `agents/stop · A1`.
    public static func call(_ entry: DaemonAPI.AuditEntry) -> String {
        [entry.method, entry.target].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Kept for 90 days".
    public static func kept(_ days: Int) -> String {
        days == 1 ? "Kept for 1 day" : "Kept for \(days) days"
    }

    /// The choices, with the days set now when they are not one of them.
    public static func choices(with days: Int) -> [Int] {
        Array(Set(dayChoices + [days])).sorted()
    }

    /// How many entries in a list are older than `days`: nil when the list leaves older
    /// ones out, so the count is not known (#2067).
    public static func older(_ list: DaemonAPI.AuditList, than days: Int, now: Date = Date()) -> Int? {
        guard !list.more else { return nil }
        let cut = now.addingTimeInterval(-Double(days) * 86_400)
        return list.entries.filter { $0.at < cut }.count
    }

    /// The question before a shorter time is saved (#2067).
    public static func shorterTitle(_ days: Int) -> String {
        "Keep the audit for \(days == 1 ? "1 day" : "\(days) days")?"
    }

    /// What a shorter time deletes, and how to keep it: the sweep waits a day. Everyone's
    /// entries, also while Whose names one person, whose list cannot count them: the caller
    /// passes no count then (#2192).
    public static func shorterMessage(from: Int, to: Int, older: Int?) -> String {
        let span = from - to == 1 ? "1 day" : "\(from - to) days"
        let count = older.map { $0 == 1 ? ", 1 entry now" : ", \($0) entries now" } ?? ""
        return "Everyone's entries older than \(to == 1 ? "1 day" : "\(to) days") are deleted in a day (up to \(span) of them\(count)). "
            + "To keep them, choose \(from) days again before then."
    }

    /// The button that saves a shorter time.
    public static let shorterConfirm = "Delete Them"

    /// The page's foot when it is empty.
    public static let empty = "Nothing has been done through the control plane yet. Starting, stopping or deleting an agent, answering a card, changing a setting and approving something appear here, with who did it."

    /// Entries cut into days, newest first, each day's entries newest first.
    public static func days(_ entries: [DaemonAPI.AuditEntry], calendar: Calendar = .current)
        -> [(day: Date, entries: [DaemonAPI.AuditEntry])] {
        var out: [(day: Date, entries: [DaemonAPI.AuditEntry])] = []
        for entry in entries.sorted(by: { $0.at > $1.at }) {
            let day = calendar.startOfDay(for: entry.at)
            if out.last?.day == day {
                out[out.count - 1].entries.append(entry)
            } else {
                out.append((day, [entry]))
            }
        }
        return out
    }

    /// The file an export is saved as: `audit-2026-10-20.jsonl`, or `.csv`.
    public static func exportName(_ now: Date = Date(), csv: Bool = false, calendar: Calendar = .current) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "audit-%04d-%02d-%02d.%@", day.year ?? 0, day.month ?? 0, day.day ?? 0, csv ? "csv" : "jsonl")
    }

    /// An admin's choice of whose entries to see (#2087): everyone's.
    public static let everyone = "Everyone"

    /// `audit/export`'s JSON lines as CSV, a row per entry, oldest first, for a spreadsheet;
    /// a line that is not an entry is left out. The web page's `auditCSV` makes the same.
    public static func csv(_ lines: String, hostName: (MachineRef) -> String) -> String {
        let header = ["at", "action", "method", "host", "hostName", "target", "user", "userName", "client", "clientName", "event"]
        var rows = [header.joined(separator: ",")]
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let decoder = JSONDecoder()
        for line in lines.split(whereSeparator: \.isNewline) where !line.allSatisfy(\.isWhitespace) {
            guard let entry = try? decoder.decode(DaemonAPI.AuditEntry.self, from: Data(line.utf8)) else { continue }
            let a = entry.actor
            let fields = [iso.string(from: entry.at), entry.action, entry.method, entry.host?.rawValue ?? "",
                          entry.host.map(hostName) ?? "", entry.target ?? "", a.user, a.userName ?? "",
                          a.client?.uuidString ?? "", a.clientName ?? "", a.event.map { "\($0.kind) \($0.id)" } ?? ""]
            rows.append(fields.map(csvField).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func csvField(_ text: String) -> String {
        text.contains(where: { $0 == "\"" || $0 == "," || $0 == "\n" || $0 == "\r" })
            ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
    }
}
