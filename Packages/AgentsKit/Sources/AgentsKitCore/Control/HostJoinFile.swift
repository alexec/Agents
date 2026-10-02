import Foundation

public extension DaemonAPI {
    /// How a host's joining its control plane stands (#113): what Agents Host and the
    /// window's Settings ▸ Control plane say, rather than one line in `daemon.log`.
    struct HostJoinStatus: Codable, Sendable, Hashable {
        /// It has a membership: it enrolled, and now only dials as itself.
        public var member: Bool
        /// Its uplink is up.
        public var connected: Bool
        /// Why the last try failed, as the dial or the control plane said it.
        public var problem: String?
        /// When this was so.
        public var at: Date

        public init(member: Bool, connected: Bool, problem: String? = nil, at: Date = Date()) {
            self.member = member
            self.connected = connected
            self.problem = problem
            self.at = at
        }

        /// Not connected, and a try failed: it is trying again on its backoff.
        public var failed: Bool { !connected && problem != nil }

        /// In plain words: "Couldn't join the control plane: <reason>. Trying again…".
        public var summary: String {
            if connected { return "Connected to the control plane." }
            guard let problem else { return member ? "Reconnecting to the control plane…" : "Joining the control plane…" }
            let reason = problem.hasSuffix(".") ? String(problem.dropLast()) : problem
            return member
                ? "Couldn't reach the control plane: \(reason). Trying again…"
                : "Couldn't join the control plane: \(reason). Trying again…"
        }
    }
}

/// `control-join.json` in a host's root (#113): how its join stands, for Agents Host and the
/// control plane beside it, neither of which is its client. Written by the daemon it names,
/// so one left by an earlier run is told apart by its pid.
public struct HostJoinFile: Codable, Sendable, Equatable {
    public static let name = "control-join.json"

    public var pid: Int32
    public var status: DaemonAPI.HostJoinStatus

    public init(pid: Int32, status: DaemonAPI.HostJoinStatus) {
        self.pid = pid
        self.status = status
    }

    public func write(to file: URL) {
        guard let data = try? JSONEncoder.iso8601.encode(self) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// The status at `file`, if the daemon running as `pid` wrote it; any daemon's when
    /// `pid` is nil and the one that wrote it is still running.
    public static func read(_ file: URL, pid: Int32? = nil) -> DaemonAPI.HostJoinStatus? {
        guard let data = try? Data(contentsOf: file),
              let read = try? JSONDecoder.iso8601.decode(HostJoinFile.self, from: data) else { return nil }
        if let pid { return read.pid == pid ? read.status : nil }
        return kill(read.pid, 0) == 0 || errno == EPERM ? read.status : nil
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
