import Foundation

/// A way to reach `agentsd` on this machine: its Unix socket. Nothing is started from
/// here (058): a Mac's daemon is Agents Host's launch agent and a server's is its own, so
/// a client that finds nobody listening says so. `agentsd mcp` reaches its daemon this
/// way for an agent's own tools (FR-021).
public struct SocketLink: DaemonLink {
    private let locations: StoreLocations

    public init(locations: StoreLocations = .default) {
        self.locations = locations
    }

    public func transport() async throws -> any LineTransport {
        FDTransport(socket: try connectUnixSocket(path: locations.socket.path))
    }

    public func start() async throws {
        throw DaemonClient.ConnectError.couldNotConnect
    }
}

public extension DaemonClient {
    /// This machine's daemon, at the socket in its root.
    init(locations: StoreLocations = .default) {
        self.init(link: SocketLink(locations: locations))
    }
}
