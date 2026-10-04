import Foundation

/// What every paired client may do: everything the Mac's own window may (#111, 2026-10-02).
///
/// There were two grants, operator and device (058, R4). A device could already start
/// agents and open terminals on any host, so it could run any command there, and the
/// split protected the hosts very little while asking a question on every pairing sheet.
/// Now there is one. The word stays on the wire, always `operator`, for builds from
/// before: an older control plane copy reading `clients.json`, an older host opening a
/// channel, an older Remote or web page reading a code. Nothing here reads it.
public enum LegacyGrant {
    /// What is written where an older build expects a grant: the one that may do
    /// everything, which is what every client now may.
    public static let everything = "operator"
}

/// A paired screen: the Mac window, an iPhone, an iPad, a browser on the control plane's
/// own Mac (071). `clients.json` under the control root, which is today's `devices.json`
/// with a Mac allowed.
public struct ClientRecord: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case mac, iPhone, iPad, unknown
        /// The web remote (071): pairs and connects only through the loopback listener,
        /// and has no relay mailbox, so it is never a notice's device.
        case browser

        /// A kind a later build added reads as `unknown`, so an older window can still list
        /// every client.
        public init(from decoder: any Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }

        /// A phone or an iPad, or a device paired before kinds were said: what presence
        /// is reported under as itself, and what a notice may be sealed to. Not the Mac's
        /// window, and not a browser, which has no mailbox (071).
        public var isDevice: Bool {
            switch self {
            case .iPhone, .iPad, .unknown: true
            case .mac, .browser: false
            }
        }
    }

    /// The pre-shared key's identity is `d:<id>`, as it is for a device today.
    public var id: UUID
    public var name: String
    public var kind: Kind
    /// P256, x963. The key the client's PSK is derived from and notices are sealed to.
    public var publicKey: Data
    public var paired: Date
    public var lastSeen: Date?
    /// A device's own report of whether it may show a notification (021).
    public var mayNotify: Bool?
    /// Whose it is (FR-012). One person for now; absent in records written before the store.
    public var owner: PersonID?
    /// Bumped on every write, so no two versions of a record have the same bytes
    /// (contracts/store.md rule 10).
    public var rev: Int
    /// Forgotten: kept as a tombstone, read as absent (rule 11).
    public var forgotten: Bool?
    /// When it was forgotten: the sweep deletes the tombstone seven days on (#174).
    public var forgottenAt: Date?
    /// The newest list of endpoints it has said it holds (R16); nil from a build that
    /// keeps none.
    public var knownEpoch: Int?

    public init(id: UUID, name: String, kind: Kind, publicKey: Data,
                paired: Date, lastSeen: Date? = nil, mayNotify: Bool? = nil,
                owner: PersonID? = nil, rev: Int = 0, forgotten: Bool? = nil) {
        self.owner = owner
        self.rev = rev
        self.forgotten = forgotten
        self.id = id
        self.name = name
        self.kind = kind
        self.publicKey = publicKey
        self.paired = paired
        self.lastSeen = lastSeen
        self.mayNotify = mayNotify
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, publicKey, grant, paired, lastSeen, mayNotify, owner, rev, forgotten, forgottenAt, knownEpoch
    }

    /// A record's `grant`, `device` or `operator`, is not read: every client may do
    /// everything (#111).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind)
        publicKey = try c.decode(Data.self, forKey: .publicKey)
        paired = try c.decode(Date.self, forKey: .paired)
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen)
        mayNotify = try c.decodeIfPresent(Bool.self, forKey: .mayNotify)
        owner = try c.decodeIfPresent(PersonID.self, forKey: .owner)
        rev = try c.decode(Int.self, forKey: .rev)
        forgotten = try c.decodeIfPresent(Bool.self, forKey: .forgotten)
        forgottenAt = try c.decodeIfPresent(Date.self, forKey: .forgottenAt)
        knownEpoch = try c.decodeIfPresent(Int.self, forKey: .knownEpoch)
    }

    /// Written with `grant: operator`, which an older copy of the control plane needs to
    /// read the record at all, and which tells it the truth.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encode(publicKey, forKey: .publicKey)
        try c.encode(LegacyGrant.everything, forKey: .grant)
        try c.encode(paired, forKey: .paired)
        try c.encodeIfPresent(lastSeen, forKey: .lastSeen)
        try c.encodeIfPresent(mayNotify, forKey: .mayNotify)
        try c.encodeIfPresent(owner, forKey: .owner)
        try c.encode(rev, forKey: .rev)
        try c.encodeIfPresent(forgotten, forKey: .forgotten)
        try c.encodeIfPresent(forgottenAt, forKey: .forgottenAt)
        try c.encodeIfPresent(knownEpoch, forKey: .knownEpoch)
    }

    /// A device paired before the control plane existed. It keeps its id and key, so its
    /// pre-shared key is unchanged and it connects without pairing again (FR-024).
    public init(device: Device) {
        let kind: Kind = switch device.kind {
        case .iPhone: .iPhone
        case .iPad: .iPad
        case .unknown: .unknown
        }
        self.init(id: device.id, name: device.name, kind: kind, publicKey: device.publicKey,
                  paired: device.announcedAt, lastSeen: device.lastSeenAt,
                  mayNotify: device.mayNotify)
    }
}

/// How the control plane reaches a host: every host connects out now, with a key of its
/// own (FR-010). Hosts the control plane reached over ssh are gone (058, T073); a record
/// that still says so is read as a host that dials out, which it becomes when it next
/// installs.
public enum HostReach: Codable, Hashable, Sendable {
    case dialOut

    private enum Keys: String, CodingKey { case dialOut }

    public init(from decoder: any Decoder) throws { self = .dialOut }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode([String: String](), forKey: .dialOut)
    }
}

/// A machine that runs agents. `hosts.json` under the control root.
public struct HostRecord: Codable, Hashable, Sendable, Identifiable {
    /// `mac` for the host a set-up was moved from (R7, R11), so what was saved against it
    /// still finds it; otherwise made by `HostID.make`.
    public var id: HostID
    public var name: String
    /// For a host that connects out; its PSK is derived from it with "agents-host-v1".
    public var publicKey: Data?
    public var reach: HostReach
    public var platform: String
    public var version: String
    /// Whether `hosts/install` put it there, so removing it can offer to take it away.
    public var installed: Bool
    /// The machine it runs on, so a window can tell a host on its own Mac (R11).
    public var machineID: String?
    /// A macOS host that runs the iCloud relay and mailbox for its person's devices (R10):
    /// `agents-relay`, which runs no agents. Nil for any other host; false while switched
    /// off with `hosts/setRelay`.
    public var relay: Bool?
    /// The hosts whose sign-in this host may use, by runtime, relayed through the control
    /// plane (058, T091): an operator said yes to each.
    public var signInFrom: [String: HostID]?
    public var owner: PersonID?
    /// As `ClientRecord.rev`.
    public var rev: Int
    /// Removed: kept as a tombstone, read as absent.
    public var forgotten: Bool?
    /// As `ClientRecord.forgottenAt`.
    public var forgottenAt: Date?
    /// As `ClientRecord.knownEpoch`.
    public var knownEpoch: Int?

    public init(id: HostID, name: String, publicKey: Data? = nil, reach: HostReach = .dialOut,
                platform: String = "", version: String = "", installed: Bool = false,
                machineID: String? = nil, relay: Bool? = nil, owner: PersonID? = nil,
                rev: Int = 0, forgotten: Bool? = nil) {
        self.relay = relay
        self.owner = owner
        self.rev = rev
        self.forgotten = forgotten
        self.id = id
        self.name = name
        self.publicKey = publicKey
        self.reach = reach
        self.platform = platform
        self.version = version
        self.installed = installed
        self.machineID = machineID
    }
}

/// Where a host is, as far as the control plane knows. Sent as `control/hostChanged`.
public enum HostState: Codable, Hashable, Sendable {
    case online
    case offline(since: Date)
    case connecting
    case needsUpdate(from: String, to: String)
    case failed(reason: String)

    public var isOnline: Bool { self == .online }
}

/// A one-time code the control plane shows, and what it lets its holder become.
public struct PairingCode: Codable, Hashable, Sendable {
    public enum Purpose: Codable, Hashable, Sendable {
        case client
        case host
    }

    public var purpose: Purpose
    /// The pre-shared secret for the first connection: identity `p:` for a client, `e:`
    /// for a host.
    public var secret: Data
    public var expires: Date
    /// Where the control plane may be reached: a Bonjour name, `host:port`.
    public var addresses: [String]
    /// The control plane's own key, so the new party can derive its PSK afterwards.
    public var controlKey: Data

    public init(purpose: Purpose, secret: Data, expires: Date, addresses: [String], controlKey: Data) {
        self.purpose = purpose
        self.secret = secret
        self.expires = expires
        self.addresses = addresses
        self.controlKey = controlKey
    }

    public static let lifetime: TimeInterval = 5 * 60
}

/// `control.json`: what the control plane is.
public struct ControlSettings: Codable, Hashable, Sendable {
    public var name: String
    public var port: Int
    /// The host on the same machine. A legacy client's bare lines go there.
    public var homeHost: HostID?
    public var machineID: String
    /// The one address clients and hosts are given (R8), and the pin of its certificate
    /// when that is not publicly trusted (R6). Absent on the first build's control plane.
    public var url: String?
    public var pin: String?
    /// Every place it answers, in the order members should try, once announced (R16), and
    /// the `epoch` that goes up whenever the list changes. Members are given both in `ok`.
    public var endpoints: [ControlEndpoint]?
    public var epoch: Int?
    /// The control plane's public key, X9.63. The private half is never in the store.
    public var controlKey: Data?
    public var owner: PersonID?
    public var created: Date?
    public var rev: Int?

    public init(name: String, port: Int = 8790, homeHost: HostID? = nil, machineID: String,
                url: String? = nil, pin: String? = nil, controlKey: Data? = nil,
                owner: PersonID? = nil, created: Date? = nil) {
        self.name = name
        self.port = port
        self.homeHost = homeHost
        self.machineID = machineID
        self.url = url
        self.pin = pin
        self.controlKey = controlKey
        self.owner = owner
        self.created = created
    }
}

/// Whom records belong to (FR-012). One person per control plane for now; the id is
/// there so a team can be added later without moving what is stored.
public struct PersonID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }
    public static func make() -> PersonID { PersonID(rawValue: UUID().uuidString.lowercased()) }
}

/// `people/<id>.json`.
public struct Person: Codable, Hashable, Sendable {
    public var id: PersonID
    public var name: String
    public init(id: PersonID, name: String) {
        self.id = id
        self.name = name
    }
}

/// `leases/<host>.json`: which copy holds a host's uplink (R5, data-model.md "Lease").
public struct HostLease: Codable, Hashable, Sendable {
    public var host: HostID
    public var copy: String
    /// Bumped on every takeover, so a lease never repeats its bytes (rule 10).
    public var epoch: Int
    public var expires: Date
    public init(host: HostID, copy: String, epoch: Int, expires: Date) {
        self.host = host
        self.copy = copy
        self.epoch = epoch
        self.expires = expires
    }
    public static let lifetime: TimeInterval = 30
    public static let renewEvery: TimeInterval = 10
}

/// `copies/<id>.json`: a live copy of the control plane, and where the others reach it.
public struct CopyRecord: Codable, Hashable, Sendable {
    public var id: String
    public var peerURL: String
    public var started: Date
    public var heartbeat: Date
    public init(id: String, peerURL: String, started: Date, heartbeat: Date) {
        self.id = id
        self.peerURL = peerURL
        self.started = started
        self.heartbeat = heartbeat
    }
    public static let beatEvery: TimeInterval = 10
    public static let goneAfter: TimeInterval = 30
}

/// `events/<day>/<ulid>.json`: a change, for a copy that missed its broadcast.
public struct ControlEvent: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// `grantChanged` is from a copy older than #111; read, and nothing follows from it.
        case clientForgotten, grantChanged, clientPaired, hostEnrolled, hostRemoved, hostMoved
        /// The control plane's endpoints changed (R16): members reconnect for the list.
        case endpointsChanged
    }
    public var kind: Kind
    public var subject: String
    public var at: Date
    public var by: String
    public init(kind: Kind, subject: String, at: Date, by: String) {
        self.kind = kind
        self.subject = subject
        self.at = at
        self.by = by
    }
}
