import AgentsKitCore
import Foundation

/// How the window reaches a server's daemon (037): the Mac's own `SocketLink`, pointed at
/// the socket the ssh master forwards, and a `start` that runs the daemon over ssh.
///
/// It never starts a master. With none running, there is nothing to connect through and
/// nothing to start the daemon with, and that is `offline`, fast: the one that owns the
/// master decides when to try again.
public struct ServerLink: DaemonLink {
    public let socket: URL
    public let installer: ServerInstaller
    private let masterIsUp: @Sendable () async -> Bool

    public init(socket: URL, installer: ServerInstaller, masterIsUp: @escaping @Sendable () async -> Bool) {
        self.socket = socket
        self.installer = installer
        self.masterIsUp = masterIsUp
    }

    public func transport() async throws -> any LineTransport {
        guard await masterIsUp() else { throw HostProblem.offline }
        return FDTransport(socket: try connectUnixSocket(path: socket.path(percentEncoded: false)))
    }

    /// Nothing answered through the forward: the server's daemon is not running, after
    /// a reboot or before its first start. Start it; it detaches and this returns, and
    /// `DaemonClient.connect` waits for it to answer.
    public func start() async throws {
        guard await masterIsUp() else { throw HostProblem.offline }
        try await installer.startDaemon()
    }
}
