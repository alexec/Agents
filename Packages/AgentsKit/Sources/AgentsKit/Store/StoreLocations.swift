import Foundation

/// Where everything lives. Injectable, so tests use a temporary directory and never go
/// near the real one.
public struct StoreLocations: Sendable {
    public var root: URL

    public init(root: URL) { self.root = root }

    public static var `default`: StoreLocations {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return StoreLocations(root: base.appendingPathComponent("Agents", isDirectory: true))
    }

    public var socket: URL { root.appendingPathComponent("daemon.sock") }
    public var lock: URL { root.appendingPathComponent("daemon.lock") }
    public var log: URL { root.appendingPathComponent("daemon.log") }
    public var agents: URL { root.appendingPathComponent("agents", isDirectory: true) }
    /// Every project we have been told about. One file, because the only things in it
    /// are the two a project's folder cannot tell us: that it is archived, and that it
    /// was added before anything ran in it.
    public var projects: URL { root.appendingPathComponent("projects.json") }

    public func agent(_ id: UUID) -> URL {
        agents.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func record(_ id: UUID) -> URL { agent(id).appendingPathComponent("agent.json") }
    public func transcript(_ id: UUID) -> URL { agent(id).appendingPathComponent("transcript.jsonl") }

    public func createDirectories() throws {
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    }
}

enum StoreCoding {
    /// ISO 8601 with fractional seconds: the record stays readable with `cat`, and a
    /// timestamp survives a round trip to the millisecond. Anything finer than that
    /// does not, which matters nowhere and is worth knowing anyway.
    nonisolated(unsafe) private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(dateFormatter.string(from: date))
        }
        e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = dateFormatter.date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(), debugDescription: "not an ISO 8601 date: \(text)")
            }
            return date
        }
        return d
    }()
}
