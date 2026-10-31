import Foundation

/// Where the audit is sent (#1001): syslog or HTTP sinks an admin sets in the Console, which
/// get each audit entry as the control plane writes it.
public extension DaemonAPI {
    /// One sink. `token`, for HTTP, is only ever sent; the control plane answers `hasToken`.
    struct AuditSink: Codable, Sendable, Hashable {
        public var kind: String
        public var address: String
        public var token: String?
        public var hasToken: Bool?

        public init(kind: String, address: String, token: String? = nil, hasToken: Bool? = nil) {
            self.kind = kind
            self.address = address
            self.token = token
            self.hasToken = hasToken
        }
    }

    /// A sink and how this copy of the control plane is sending to it.
    struct AuditSinkStatus: Codable, Sendable, Hashable {
        public var sink: AuditSink
        public var queued: Int
        public var dropped: Int
        public var sentAt: Date?
        public var lastError: String?
    }

    /// `audit/setSinks`: at most 4; one with no token keeps the one it had.
    struct AuditSinks: Codable, Sendable, Hashable {
        public var sinks: [AuditSink]

        public init(sinks: [AuditSink]) { self.sinks = sinks }
    }

    /// What `audit/sinks` and `audit/setSinks` answer.
    struct AuditSinksState: Codable, Sendable, Hashable {
        public var sinks: [AuditSinkStatus]
    }
}

public extension DaemonAPI.Method {
    /// `Empty` → `AuditSinksState`, an admin's only (#1001).
    static let auditSinks = "audit/sinks"
    /// `AuditSinks` → `AuditSinksState`, an admin's only (#1001).
    static let auditSetSinks = "audit/setSinks"
}
