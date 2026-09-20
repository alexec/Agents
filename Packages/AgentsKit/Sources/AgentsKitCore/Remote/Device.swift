import Foundation

/// A paired device: 005's record, built here because 005 never built it.
///
/// Slice A reads it only to route — the ladder's device rungs need to know what is
/// approved, what kind it is, and whether it may show a notification — and stores none.
/// Slice C fills in the store, the key and the sealing.
///
/// `kind` is load-bearing, not decorative: FR-009 makes the iPhone the default when
/// nothing says where the person is, so a device that reports `unknown` cannot be the
/// default. `mayNotify` is the device's report of its own authorisation, refreshed when it
/// connects — `nil` means it has not said, and a device that has not said is not chosen.
public struct Device: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case iPhone, iPad, unknown
    }

    public var id: UUID
    public var publicKey: Data
    public var name: String
    public var kind: Kind
    public var announcedAt: Date
    public var approvedAt: Date?
    public var lastSeenAt: Date?
    public var mayNotify: Bool?

    public init(id: UUID, publicKey: Data = Data(), name: String, kind: Kind,
                announcedAt: Date, approvedAt: Date? = nil, lastSeenAt: Date? = nil,
                mayNotify: Bool? = nil) {
        self.id = id
        self.publicKey = publicKey
        self.name = name
        self.kind = kind
        self.announcedAt = announcedAt
        self.approvedAt = approvedAt
        self.lastSeenAt = lastSeenAt
        self.mayNotify = mayNotify
    }

    /// Sealed to, and routed to, only while approved.
    public var isApproved: Bool { approvedAt != nil }

    /// Whether the ladder may choose this device at all: approved, and it has said it
    /// can show a notification. Choosing one that cannot would be choosing silence.
    public var isEligible: Bool { isApproved && mayNotify == true }
}
