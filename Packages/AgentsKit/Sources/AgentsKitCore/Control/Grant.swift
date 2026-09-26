import Foundation

/// What a paired client may do (058, R4).
///
/// Two, and only two, because both already exist and have been reviewed: an operator may
/// do what the Mac's own window may, which is everything, and a device may do what a
/// paired phone may. The control plane checks a client's grant with the very allowlists
/// the daemon uses for its own connections, and each host checks it again.
public enum Grant: String, Codable, Hashable, Sendable, CaseIterable {
    case `operator`
    case device

    /// The daemon role a channel opened with this grant becomes on the host.
    public var role: ConnectionRole {
        switch self {
        case .operator: .control
        case .device: .device
        }
    }

    public func allows(_ method: String) -> Bool { role.allows(method) }
}

/// A paired screen: the Mac window, an iPhone, an iPad. `clients.json` under the control
/// root, which is today's `devices.json` with a grant added and a Mac allowed.
public struct ClientRecord: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case mac, iPhone, iPad, unknown
    }

    /// The pre-shared key's identity is `d:<id>`, as it is for a device today.
    public var id: UUID
    public var name: String
    public var kind: Kind
    /// P256, x963. The key the client's PSK is derived from and notices are sealed to.
    public var publicKey: Data
    public var grant: Grant
    public var paired: Date
    public var lastSeen: Date?
    /// A device's own report of whether it may show a notification (021).
    public var mayNotify: Bool?

    public init(id: UUID, name: String, kind: Kind, publicKey: Data, grant: Grant,
                paired: Date, lastSeen: Date? = nil, mayNotify: Bool? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.publicKey = publicKey
        self.grant = grant
        self.paired = paired
        self.lastSeen = lastSeen
        self.mayNotify = mayNotify
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
                  grant: .device, paired: device.announcedAt, lastSeen: device.lastSeenAt,
                  mayNotify: device.mayNotify)
    }
}

/// How the control plane reaches a host.
public enum HostReach: Codable, Hashable, Sendable {
    /// The host connects out, with a key of its own (FR-010).
    case dialOut
    /// The control plane holds an ssh forward to the host's socket (FR-012, R8).
    case ssh(destination: String, hostKeyFingerprint: String?)

    public var isSSH: Bool { if case .ssh = self { return true }; return false }
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

    public init(id: HostID, name: String, publicKey: Data? = nil, reach: HostReach = .dialOut,
                platform: String = "", version: String = "", installed: Bool = false,
                machineID: String? = nil) {
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
        case client(Grant)
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

    public init(name: String, port: Int = 8790, homeHost: HostID? = nil, machineID: String) {
        self.name = name
        self.port = port
        self.homeHost = homeHost
        self.machineID = machineID
    }
}
