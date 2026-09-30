import Foundation

/// What the control plane answers itself, and says (058, contracts/control-api.md).
public extension DaemonAPI.Method {
    static let controlStatus = "control/status"
    static let hostsList = "hosts/list"
    static let hostsStartEnroll = "hosts/startEnroll"
    static let hostsInstall = "hosts/install"
    static let hostsCheckAgain = "hosts/checkAgain"
    static let hostsUpdate = "hosts/update"
    static let hostsRemove = "hosts/remove"
    /// `{host, relay}`: whether a host carries the person's devices through iCloud (T097).
    static let hostsSetRelay = "hosts/setRelay"
    static let clientsList = "clients/list"
    static let clientsStartPairing = "clients/startPairing"
    static let clientsStopPairing = "clients/stopPairing"
    static let clientsAnnounce = "clients/announce"
    static let clientsSetGrant = "clients/setGrant"
    static let clientsForget = "clients/forget"
    /// How each client reaches the control plane now (frame N, T080).
    static let clientsConnections = "clients/connections"

    // A host, on its channel 0.
    static let hostsAnnounce = "hosts/announce"
    static let hostHello = "host/hello"
    static let attentionNeed = "attention/need"
    static let controlPing = "control/ping"

    // To a relay host, on its channel 0 (058, T096–T097): notifications, never answered.
    /// `RelayDevices`: the devices it may carry for, with their keys.
    static let relayDevices = "relay/devices"
    /// `RelayDelivery`: one mailbox item to seal and post.
    static let relayDeliver = "relay/deliver"
}

public extension DaemonAPI.Notification {
    static let controlHostChanged = "control/hostChanged"
    static let controlClientChanged = "control/clientChanged"
    static let controlPairingChanged = "control/pairingChanged"
    static let controlInstallProgress = "control/installProgress"
}

public extension DaemonAPI {
    /// `control/status`.
    struct ControlStatus: Codable, Sendable, Hashable {
        public var name: String
        public var version: String
        public var homeHost: HostID?
        public var machineID: String
        /// When this run of the control plane started (frame D).
        public var startedAt: Date?
        /// The port clients and hosts reach it on over the network, if it listens on one.
        public var port: Int?
        /// Whether devices reach it through iCloud when away from home (R6).
        public var awayFromHome: Bool?
        /// The asking client's own record, so a window can mark itself "you".
        public var you: UUID?
        /// The public key of the host that relays through iCloud, if one does (T077): what a
        /// device keeps so it can reach the control plane through the relay when away.
        public var relayKey: Data?

        public init(name: String, version: String, homeHost: HostID?, machineID: String,
                    startedAt: Date? = nil, port: Int? = nil, awayFromHome: Bool? = nil) {
            self.name = name
            self.version = version
            self.homeHost = homeHost
            self.machineID = machineID
            self.startedAt = startedAt
            self.port = port
            self.awayFromHome = awayFromHome
        }
    }

    /// One row of `hosts/list`.
    struct ControlHost: Codable, Sendable, Hashable, Identifiable {
        public var id: HostID
        public var name: String
        public var platform: String
        public var version: String
        /// `online`, `offline`, `connecting`, `needsUpdate` or `failed`.
        public var state: String
        public var reach: String
        public var machineID: String?
        /// A relay host (`agents-relay`): it carries devices through iCloud and runs no agents.
        public var relay: Bool?

        public init(id: HostID, name: String, platform: String, version: String, state: String,
                    reach: String, machineID: String?, relay: Bool? = nil) {
            self.relay = relay
            self.id = id
            self.name = name
            self.platform = platform
            self.version = version
            self.state = state
            self.reach = reach
            self.machineID = machineID
        }
    }

    /// `control/hostChanged`.
    struct ControlHostChanged: Codable, Sendable, Hashable {
        public var host: HostID
        /// As in `ControlHost.state`, or `removed`.
        public var state: String
    }

    /// `host/hello`, on every connect of an uplink.
    struct HostHello: Codable, Sendable, Hashable {
        /// Which host this is. Said only on the control plane's local socket, where the
        /// uid and the code signature are the door; over TLS the key says it, and this
        /// is ignored.
        public var host: HostID?
        public var version: String
        public var platform: String
        public var machineID: String
        public var name: String?
        /// Said by `agents-relay` (T096): this host only relays, and gets no client channels.
        public var relay: Bool?

        public init(host: HostID? = nil, version: String, platform: String, machineID: String, name: String? = nil,
                    relay: Bool? = nil) {
            self.relay = relay
            self.host = host
            self.version = version
            self.platform = platform
            self.machineID = machineID
            self.name = name
        }
    }

    /// `attention/need`, unsealed, on a host's channel 0 (058, R6).
    ///
    /// A host no longer knows devices, so it cannot seal. It sends the need and whether
    /// it should buzz; `{withdraw}` is the need being over. The control plane chooses
    /// the device and seals.
    struct AttentionNeed: Codable, Sendable, Hashable {
        public var need: Need?
        public var headline: Headline?
        public var buzz: Bool?
        public var withdraw: NeedID?

        public init(need: Need?, headline: Headline?, buzz: Bool?, withdraw: NeedID?) {
            self.need = need
            self.headline = headline
            self.buzz = buzz
            self.withdraw = withdraw
        }

        public static func offer(_ need: Need, buzz: Bool) -> AttentionNeed {
            AttentionNeed(need: need, headline: need.headline, buzz: buzz, withdraw: nil)
        }

        public static func withdraw(_ id: NeedID) -> AttentionNeed {
            AttentionNeed(need: nil, headline: nil, buzz: nil, withdraw: id)
        }
    }

    /// `clients/setGrant`.
    struct ClientGrantRequest: Codable, Sendable, Hashable {
        public var client: UUID
        public var grant: Grant
        public init(client: UUID, grant: Grant) {
            self.client = client
            self.grant = grant
        }
    }

    /// `clients/forget`, `hosts/remove`.
    struct ClientRequest: Codable, Sendable, Hashable {
        public var client: UUID
        public init(client: UUID) { self.client = client }
    }

    struct HostRequest: Codable, Sendable, Hashable {
        public var host: HostID
        public var purge: Bool?
        public init(host: HostID, purge: Bool? = nil) {
            self.host = host
            self.purge = purge
        }
    }

    /// One row of `clients/connections`: a client connected now, and how.
    struct ClientConnection: Codable, Sendable, Hashable {
        public var client: UUID
        /// Only through the iCloud relay.
        public var relayed: Bool
        /// The relaying host's name, when relayed.
        public var through: String?
        public init(client: UUID, relayed: Bool, through: String? = nil) {
            self.client = client
            self.relayed = relayed
            self.through = through
        }
    }

    /// `hosts/setRelay`.
    struct HostRelayRequest: Codable, Sendable, Hashable {
        public var host: HostID
        public var relay: Bool
        public init(host: HostID, relay: Bool) {
            self.host = host
            self.relay = relay
        }
    }

    /// `relay/devices`: every device client, with the key its frames are sealed to.
    struct RelayDevices: Codable, Sendable, Hashable {
        public struct Device: Codable, Sendable, Hashable {
            public var id: UUID
            public var publicKey: Data
            public init(id: UUID, publicKey: Data) {
                self.id = id
                self.publicKey = publicKey
            }
        }
        public var devices: [Device]
        public init(devices: [Device]) { self.devices = devices }
    }

    /// `relay/deliver`: what the control plane chose (T097). The relay host seals the
    /// headline to `publicKey` and posts it for `device`; no headline is a withdrawal.
    struct RelayDelivery: Codable, Sendable, Hashable {
        public var needID: NeedID
        public var device: UUID
        public var publicKey: Data?
        public var headline: Headline?
        public var alert: Bool
        public init(needID: NeedID, device: UUID, publicKey: Data? = nil, headline: Headline? = nil, alert: Bool = false) {
            self.needID = needID
            self.device = device
            self.publicKey = publicKey
            self.headline = headline
            self.alert = alert
        }
    }
}
