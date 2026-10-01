import AgentsKitCore
import Foundation

/// Moving today's set-up across to a control plane, once, when the person chooses it
/// (058, US6, R7).
///
/// Nothing in the old root moves: it becomes this Mac's host, `mac`, so no agent,
/// conversation or project can be lost on the way (FR-023, SC-006). What changes is
/// written beside it, in the control root: the devices the host paired become device
/// clients with their own keys, so they connect afterwards without pairing again
/// (FR-024). The servers the window reached by ssh are handed to the control plane,
/// which reaches them by ssh from then on.
public enum ControlMove {
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        /// The control root already has clients or hosts of its own: this is not a move.
        case alreadyUsed

        public var description: String {
            switch self {
            case .alreadyUsed: "There is already a control plane here with clients or hosts of its own."
            }
        }
    }

    /// What a move would keep, for the sheet to say (frame I).
    public struct Summary: Sendable, Equatable {
        public var agents: Int
        public var devices: [String]
        public var servers: [String]
    }

    public static func summary(of locations: StoreLocations) -> Summary {
        let agents = ((try? FileManager.default.contentsOfDirectory(atPath: locations.agents.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.count
        return Summary(agents: agents,
                       devices: ControlRecords.legacyDevices(at: locations.devices).map(\.name),
                       servers: HostStore(locations: locations).load().all.map(\.label))
    }

    /// The control plane's store, with the host's devices as device clients and this
    /// Mac's host named as the home host: the one a running copy of `agents-control`
    /// serves, on this Mac or in a bucket (058, T084). Its settings are the copy's, so
    /// none are made here. The old root is only read. Run again after a move that got
    /// this far and stopped, it finds its own work and changes nothing.
    public static func prepare(_ records: ControlRecords, from locations: StoreLocations) async throws {
        let devices = ControlRecords.legacyDevices(at: locations.devices)
        let ours = Set(devices.map(\.id))
        let foreign = await records.clients.filter { !ours.contains($0.id) && !($0.kind == .mac && $0.publicKey.isEmpty) }
        guard foreign.isEmpty, await records.hosts.allSatisfy({ $0.id == .mac }) else { throw Refusal.alreadyUsed }
        for device in devices where await records.client(device.id) == nil { try await records.save(device) }
        _ = try await records.changeSettings { $0.homeHost = .mac }
    }

    /// The servers the window reached by ssh before the move.
    public static func servers(of locations: StoreLocations) -> [ServerHost] {
        HostStore(locations: locations).load().all
    }

    /// The last step: the window's own list of servers is kept, renamed, not deleted.
    public static func retireServers(of locations: StoreLocations) throws {
        let file = locations.hosts
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let moved = file.appendingPathExtension("moved")
        try? FileManager.default.removeItem(at: moved)
        try FileManager.default.moveItem(at: file, to: moved)
    }
}
