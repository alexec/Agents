import Foundation

/// Bounds the amount of runtime stderr written to the daemon log (#222).
struct DaemonStderrBudget {
    struct Entry {
        var minute: Date
        var bytes = 0
        var suppressed = 0
    }

    enum Decision: Equatable {
        case log(String)
        case suppress(total: Int)
    }

    private(set) var entries: [UUID: Entry] = [:]

    mutating func consume(_ text: String, from agentID: UUID, at now: Date) -> Decision {
        var entry = entries[agentID] ?? Entry(minute: now)
        if now.timeIntervalSince(entry.minute) >= 60 {
            entry.minute = now
            entry.bytes = 0
        }

        let chunk = String(decoding: text.utf8.prefix(1024), as: UTF8.self)
        let byteCount = chunk.utf8.count
        let decision: Decision
        if entry.bytes + byteCount <= 4096 {
            entry.bytes += byteCount
            decision = .log(chunk)
        } else {
            entry.suppressed += 1
            decision = .suppress(total: entry.suppressed)
        }
        entries[agentID] = entry
        return decision
    }

    mutating func remove(_ agentID: UUID) {
        entries[agentID] = nil
    }
}
