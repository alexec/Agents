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
        FDTransport(socket: try connectSocket(path: locations.socket.path))
    }

    private func connectSocket(path: String) throws -> Int32 {
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
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard result == 0 else {
            close(fd)
            throw DaemonClient.ConnectError.couldNotConnect
        }
        return fd
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
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // CLOEXEC_DEFAULT so the helper starts with nothing of the app's but the three
        // descriptors named below. It outlives the window on purpose; what it inherits
        // would outlive it too.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, locations.log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        var pid: pid_t = 0
        let arguments: [String] = [helper.path]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { for pointer in argv where pointer != nil { free(pointer) } }

        // Said rather than inherited. A window started with `--root` has the path in
        // its arguments and not in its environment, and the daemon it starts has to
        // end up in the same place or it is a different daemon.
        var inherited = ProcessInfo.processInfo.environment
        inherited[StoreLocations.rootVariable] = locations.root.path
        var environment: [UnsafeMutablePointer<CChar>?] = inherited
            .map { strdup("\($0.key)=\($0.value)") }
        environment.append(nil)
        defer { for pointer in environment where pointer != nil { free(pointer) } }

        let status = posix_spawn(&pid, helper.path, &actions, &attributes, &argv, &environment)
        guard status == 0 else {
            let reason = String(cString: strerror(status))
            throw DaemonClient.ConnectError.couldNotStartHelper("\(helper.path): \(reason)")
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
