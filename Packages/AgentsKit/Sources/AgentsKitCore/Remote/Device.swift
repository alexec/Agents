import Foundation

/// A paired device: 005's record, built here because 005 never built it.
///
/// Stored by the daemon in `devices.json`, the only thing this feature writes to disk:
/// what the person is doing right now is not a fact worth keeping, and what they
/// approved once is. One record per `id`; a reinstalled device is a new id, a new key
/// and a new approval. The public key is never rewritten under an id — a device that
/// wants a new key is a new device. Revoking **deletes** the record, which is what makes
/// the device unable to read anything, rather than a flag somebody must remember to check.
///
/// `kind` is load-bearing, not decorative: FR-009 makes the iPhone the default when
/// nothing says where the person is, so a device that reports `unknown` cannot be the
/// default. `mayNotify` is the device's report of its own authorisation, refreshed when
/// it connects — `nil` means it has not said, and a device that has not said is not
/// chosen (FR-023). `wants` is deliberately not built: every approved device is eligible
/// for everything. `unknownFields` is what keeps a record written by a future build that
/// has it from being damaged by this one, as `Agent` and `Project` already do.
public struct Device: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case iPhone, iPad, unknown
    }

    public var id: UUID
    /// P256, as the device made it. Everything sealed to this device is sealed to it.
    public var publicKey: Data
    public var name: String
    public var kind: Kind
    public var announcedAt: Date
    /// `nil` means waiting for the person to say yes at the Mac.
    public var approvedAt: Date?
    public var lastSeenAt: Date?
    public var mayNotify: Bool?
    public var unknownFields: [String: JSONValue]

    public init(id: UUID, publicKey: Data = Data(), name: String, kind: Kind,
                announcedAt: Date, approvedAt: Date? = nil, lastSeenAt: Date? = nil,
                mayNotify: Bool? = nil, unknownFields: [String: JSONValue] = [:]) {
        self.id = id
        self.publicKey = publicKey
        self.name = name
        self.kind = kind
        self.announcedAt = announcedAt
        self.approvedAt = approvedAt
        self.lastSeenAt = lastSeenAt
        self.mayNotify = mayNotify
        self.unknownFields = unknownFields
    }

    /// Sealed to, and routed to, only while approved.
    public var isApproved: Bool { approvedAt != nil }

    /// Whether the ladder may choose this device at all: approved, and it has said it
    /// can show a notification. Choosing one that cannot would be choosing silence.
    public var isEligible: Bool { isApproved && mayNotify == true }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, publicKey, name, kind, announcedAt, approvedAt, lastSeenAt, mayNotify
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        publicKey = try c.decodeIfPresent(Data.self, forKey: .publicKey) ?? Data()
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .unknown
        announcedAt = try c.decode(Date.self, forKey: .announcedAt)
        approvedAt = try c.decodeIfPresent(Date.self, forKey: .approvedAt)
        lastSeenAt = try c.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        mayNotify = try c.decodeIfPresent(Bool.self, forKey: .mayNotify)
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        let whole = (try? JSONValue(from: decoder).objectValue) ?? [:]
        unknownFields = whole.filter { !known.contains($0.key) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(publicKey, forKey: .publicKey)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(announcedAt, forKey: .announcedAt)
        try c.encodeIfPresent(approvedAt, forKey: .approvedAt)
        try c.encodeIfPresent(lastSeenAt, forKey: .lastSeenAt)
        try c.encodeIfPresent(mayNotify, forKey: .mayNotify)
        if !unknownFields.isEmpty {
            var extra = encoder.container(keyedBy: AnyKey.self)
            for (key, value) in unknownFields {
                try extra.encode(value, forKey: AnyKey(stringValue: key))
            }
        }
    }

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
