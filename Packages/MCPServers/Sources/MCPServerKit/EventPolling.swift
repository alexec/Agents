import Foundation

/// Times as the events draft carries them: ISO 8601 in UTC with milliseconds, which sort as
/// text in time order.
public enum Time {
    nonisolated(unsafe) static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) static let whole: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static let lock = NSLock()

    /// `text` as a date, with or without fractional seconds; nil when it is not one.
    public static func parse(_ text: String) -> Date? {
        lock.withLock { withFraction.date(from: text) ?? whole.date(from: text) }
    }

    /// `date` as `2026-10-01T10:00:00.000Z`.
    public static func string(_ date: Date) -> String {
        lock.withLock { withFraction.string(from: date) }
    }

    /// `text` in that form, or nil when it is not a date.
    public static func normalized(_ text: String) -> String? { parse(text).map(string) }
}

/// Where a poll has got to: a high-water time, and the ids already raised at exactly that
/// time, so events that share one time are neither lost nor raised twice. A client keeps it
/// as an opaque string (base64url of its JSON).
public struct PollCursor: Sendable, Equatable {
    public var since: String
    public var ids: [String]

    public init(since: String, ids: [String] = []) {
        self.since = since
        self.ids = ids
    }

    public var encoded: String {
        let json: JSON = ["since": .string(since), "ids": JSON(ids)]
        return json.data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The cursor `text` encodes, or -32602 when it is not one a server gave.
    public static func decode(_ text: JSON?) throws(RPCError) -> PollCursor {
        let refused = RPCError.invalidParams("cursor is not one this server gave")
        guard var b64 = text?.string else { throw refused }
        b64 = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64), let json = try? JSON.parse(data),
              let since = json["since"]?.string.flatMap(Time.normalized), let ids = json["ids"]?.array
        else { throw refused }
        return PollCursor(since: since, ids: ids.map { $0.string ?? $0.text })
    }
}

/// Something that may be raised: its id, its time (as `Time.string`), and its data, looked up
/// only once it is taken; nil data skips it, though the cursor still moves past it.
public struct Candidate: Sendable {
    public var eventId: String
    public var time: String
    public var data: @Sendable () async throws -> JSON?

    public init(eventId: String, time: String, data: @escaping @Sendable () async throws -> JSON?) {
        self.eventId = eventId
        self.time = time
        self.data = data
    }
}

/// `events/poll` over a cursor: the first poll (no cursor) gives none and starts from now; later
/// ones give what is new since, oldest first, at most `maxEvents`, with `hasMore` and a cursor
/// that goes on from the last one taken.
public struct EventPoll: Sendable {
    public var maxEvents: Int
    public var nextPollMs: Int
    /// A cursor older than this may have missed some, as the source keeps no more.
    public var historySeconds: TimeInterval

    public init(maxEvents: Int = 100, nextPollMs: Int = 30_000, historySeconds: TimeInterval = 90 * 86400) {
        self.maxEvents = maxEvents
        self.nextPollMs = nextPollMs
        self.historySeconds = historySeconds
    }

    /// The answer to `params` for `event`. `candidates` finds what happened at or after the
    /// cursor's time, and says whether its list was cut short; `mapError` turns what it or
    /// a candidate's data throws into the error to answer.
    public func poll(event: Event, params: JSON, now: Date = Date(),
                     candidates: (String) async throws -> (list: [Candidate], truncated: Bool),
                     mapError: (any Error) -> RPCError) async throws(RPCError) -> JSON {
        let asked = params["maxEvents"]?.int ?? 50
        let limit = min(maxEvents, max(1, asked))
        guard let given = params["cursor"], given != .null else {
            return ["events": [], "cursor": .string(PollCursor(since: Time.string(now)).encoded),
                    "truncated": false, "hasMore": false, "nextPollMs": .int(nextPollMs)]
        }
        let cursor = try PollCursor.decode(given)
        let seen = Set(cursor.ids)
        let found: (list: [Candidate], truncated: Bool)
        do { found = try await candidates(cursor.since) } catch { throw mapError(error) }

        let fresh = found.list
            .filter { $0.time >= cursor.since && !($0.time == cursor.since && seen.contains($0.eventId)) }
            .sorted { $0.time == $1.time ? $0.eventId < $1.eventId : $0.time < $1.time }
        let taken = fresh.prefix(limit)
        let since = taken.last?.time ?? cursor.since
        var ids = since == cursor.since ? cursor.ids : []
        for c in taken where c.time == since && !ids.contains(c.eventId) { ids.append(c.eventId) }

        var events = [JSON]()
        for c in taken {
            let data: JSON?
            do { data = try await c.data() } catch { throw mapError(error) }
            if let data {
                events.append(["eventId": .string(c.eventId), "name": .string(event.name),
                               "timestamp": .string(c.time), "data": data])
            }
        }
        let old = (Time.parse(cursor.since) ?? now) < now.addingTimeInterval(-historySeconds)
        return ["events": .array(events), "cursor": .string(PollCursor(since: since, ids: ids).encoded),
                "truncated": .bool(found.truncated || old), "hasMore": .bool(fresh.count > taken.count),
                "nextPollMs": .int(nextPollMs)]
    }
}
