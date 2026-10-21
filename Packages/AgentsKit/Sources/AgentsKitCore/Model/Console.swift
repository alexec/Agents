import Foundation

/// The Console (#1804): the control plane's app for its admins, on the web page. The window
/// and the Remote do not draw it; these types are here so `WebSignatures` names them.
public extension DaemonAPI {
    /// One machine on Console ▸ Machines: its `hosts/list` row, whose it is, and how many of
    /// its agents were running when it last listed them. Numbers only.
    struct FleetMachine: Codable, Sendable, Hashable {
        public var host: ControlHost
        /// Its person's or bot's name; empty when nobody owns it.
        public var ownerName: String
        public var bot: Bool
        public var running: Int?
        public var heardAt: Date?

        public init(host: ControlHost, ownerName: String, bot: Bool, running: Int? = nil, heardAt: Date? = nil) {
            self.host = host
            self.ownerName = ownerName
            self.bot = bot
            self.running = running
            self.heardAt = heardAt
        }
    }

    /// `console/fleet`'s answer: every machine on the control plane, for an admin.
    struct FleetBoard: Codable, Sendable, Hashable {
        public var machines: [FleetMachine]

        public init(machines: [FleetMachine]) {
            self.machines = machines
        }
    }
}

public extension DaemonAPI.Method {
    /// `Empty` → `FleetBoard` (#1804, M1). Admins only.
    static let consoleFleet = "console/fleet"
}
