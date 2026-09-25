import Foundation

/// The Mac's way to reach `agentsd`: a Unix socket, and `posix_spawn` when nothing is
/// listening on it.
///
/// This is the half of the old `DaemonClient` that cannot leave the Mac — `posix_spawn`,
/// `Bundle.main` and a socket in Application Support. The half above it moved into
/// `AgentsKitCore` so the phone could have it.
public struct SocketLink: DaemonLink {
    private let locations: StoreLocations
    private let helperURL: URL?

    public init(locations: StoreLocations = .default, helperURL: URL? = nil) {
        self.locations = locations
        self.helperURL = helperURL
    }

    public func transport() async throws -> any LineTransport {
        FDTransport(socket: try connectUnixSocket(path: locations.socket.path))
    }

    /// Start the helper in a session of its own.
    ///
    /// `POSIX_SPAWN_SETSID` is the whole trick: the helper is not in the app's process
    /// group, so quitting, crashing or force quitting the app leaves it and its agents
    /// alone. Its output goes to the log because nothing will be there to read it.
    public func start() async throws {
        let helper = try locateHelper()
        // The helper's output goes to the log, and posix_spawn refuses the whole spawn
        // if that file cannot be opened. On a first run the directory does not exist
        // yet, and the daemon that would have made it is the thing being started.
        try? locations.createDirectories()
        // Said rather than inherited. A window started with `--root` has the path in
        // its arguments and not in its environment, and the daemon it starts has to
        // end up in the same place or it is a different daemon.
        var environment = ProcessInfo.processInfo.environment
        environment[StoreLocations.rootVariable] = locations.root.path
        do {
            try Spawn.detached(executable: helper, arguments: [], environment: environment,
                               log: locations.log)
        } catch let failed as Spawn.Failed {
            throw DaemonClient.ConnectError.couldNotStartHelper(failed.description)
        }
    }

    private func locateHelper() throws -> URL {
        if let helperURL { return helperURL }
        var candidates: [URL] = []
        // In the app: Agents.app/Contents/Helpers/agentsd.
        if let helpers = Bundle.main.builtInPlugInsURL?
            .deletingLastPathComponent().appendingPathComponent("Helpers/agentsd") {
            candidates.append(helpers)
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/agentsd"))
        // Beside the executable, which is where a command-line build puts it.
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("agentsd"))
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw DaemonClient.ConnectError.noHelper(lookedIn: candidates.map(\.path))
    }
}

public extension DaemonClient {
    /// The Mac's client: the socket in Application Support, and the helper beside the
    /// app. What every call site on this platform means by `DaemonClient()`.
    init(locations: StoreLocations = .default, helperURL: URL? = nil) {
        self.init(link: SocketLink(locations: locations, helperURL: helperURL))
    }
}

/// A connected Unix socket, close-on-exec, or `couldNotConnect`. The Mac's daemon socket
/// and a server's forwarded one are reached the same way (037).
public func connectUnixSocket(path: String) throws -> Int32 {
    // The same 104 bytes `DaemonServer` refuses to exceed. Said here too, because
    // a truncated path connects to nothing and reads as "no daemon is running".
    guard path.utf8.count < 104 else { throw DaemonClient.ConnectError.socketPathTooLong(path) }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw DaemonClient.ConnectError.couldNotConnect }
    // The daemon notices the window has gone when this end closes. A child holding
    // a copy of it — the helper this same client spawns, and every shell below it —
    // would be a window that never leaves, and a daemon that never shuts down.
    fcntl(fd, F_SETFD, FD_CLOEXEC)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        path.withCString { source in
            strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, 103)
        }
    }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { POSIX.connect(fd, $0, size) }
    }
    guard result == 0 else {
        close(fd)
        throw DaemonClient.ConnectError.couldNotConnect
    }
    return fd
}
