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
    static let clientsList = "clients/list"
    static let clientsStartPairing = "clients/startPairing"
    static let clientsStopPairing = "clients/stopPairing"
    static let clientsAnnounce = "clients/announce"
    static let clientsSetGrant = "clients/setGrant"
    static let clientsForget = "clients/forget"

    // A host, on its channel 0.
    static let hostsAnnounce = "hosts/announce"
    static let hostHello = "host/hello"
    static let attentionNeed = "attention/need"
    static let controlPing = "control/ping"
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

        public init(name: String, version: String, homeHost: HostID?, machineID: String) {
            self.name = name
            self.version = version
            self.homeHost = homeHost
            self.machineID = machineID
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

        public init(id: HostID, name: String, platform: String, version: String, state: String,
                    reach: String, machineID: String?) {
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

        public init(host: HostID? = nil, version: String, platform: String, machineID: String, name: String? = nil) {
            self.host = host
            self.version = version
            self.platform = platform
            self.machineID = machineID
            self.name = name
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
}
