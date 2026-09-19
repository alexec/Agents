import Foundation

/// How the app talks to the daemon, and how the daemon gets started in the first place.
///
/// The app holds no agent state: it connects, asks, subscribes, and renders what
/// arrives. Reconnecting after the window died is the same three steps, which is why
/// there is no special case for it.
public actor DaemonClient {
    public enum ConnectError: Error, Sendable {
        case noHelper(lookedIn: [String])
        case couldNotStartHelper(String)
        case couldNotConnect
        /// A root so deep that the socket inside it cannot be addressed.
        case socketPathTooLong(String)
    }

    private let locations: StoreLocations
    private let helperURL: URL?
    private var connection: JSONRPCConnection?

    public init(locations: StoreLocations = .default, helperURL: URL? = nil) {
        self.locations = locations
        self.helperURL = helperURL
    }

    public var isConnected: Bool { connection != nil }

    /// Connect, starting the daemon if nothing answers.
    public func connect(startIfNeeded: Bool = true, timeout: Duration = .seconds(8)) async throws {
        if let connection {
            // A connection that has quietly died still looks like one, so it is asked
            // before it is trusted.
            if (try? await connection.call(DaemonAPI.Method.ping)) != nil { return }
            await connection.close()
            self.connection = nil
        }
        if let connection = try? await open() {
            self.connection = connection
            return
        }
        guard startIfNeeded else { throw ConnectError.couldNotConnect }
        try spawnHelper()

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let connection = try? await open() {
                self.connection = connection
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw ConnectError.couldNotConnect
    }

    private func open() async throws -> JSONRPCConnection {
        let fd = try connectSocket(path: locations.socket.path)
        let connection = JSONRPCConnection(transport: FDTransport(socket: fd))
        await connection.start()
        _ = try await connection.call(DaemonAPI.Method.ping)
        return connection
    }

    private func connectSocket(path: String) throws -> Int32 {
        // The same 104 bytes `DaemonServer` refuses to exceed. Said here too, because
        // a truncated path connects to nothing and reads as "no daemon is running".
        guard path.utf8.count < 104 else { throw ConnectError.socketPathTooLong(path) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConnectError.couldNotConnect }
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
            throw ConnectError.couldNotConnect
        }
        return fd
    }

    /// Start the helper in a session of its own.
    ///
    /// `POSIX_SPAWN_SETSID` is the whole trick: the helper is not in the app's process
    /// group, so quitting, crashing or force quitting the app leaves it and its agents
    /// alone. Its output goes to the log because nothing will be there to read it.
    private func spawnHelper() throws {
        let helper = try locateHelper()
        // The helper's output goes to the log, and posix_spawn refuses the whole spawn
        // if that file cannot be opened. On a first run the directory does not exist
        // yet, and the daemon that would have made it is the thing being started.
        try? locations.createDirectories()
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

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
            throw ConnectError.couldNotStartHelper("\(helper.path): \(reason)")
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
        throw ConnectError.noHelper(lookedIn: candidates.map(\.path))
    }

    // MARK: Asking

    private func connected() throws -> JSONRPCConnection {
        guard let connection else { throw ConnectError.couldNotConnect }
        return connection
    }

    @discardableResult
    public func call(_ method: String, _ params: (some Encodable)? = Optional<String>.none) async throws -> JSONValue {
        let value = try params.map { try JSONValue.encoding($0) }
        return try await connected().call(method, value)
    }

    public func call<T: Decodable>(_ method: String, _ params: (some Encodable)? = Optional<String>.none,
                                   returning: T.Type) async throws -> T {
        try await call(method, params).decode(T.self)
    }

    public nonisolated func notifications() -> AsyncStream<(method: String, params: JSONValue?)> {
        AsyncStream { continuation in
            Task {
                guard let connection = await self.connection else { continuation.finish(); return }
                for await notification in connection.incomingNotifications() {
                    continuation.yield(notification)
                }
                continuation.finish()
            }
        }
    }

    public func disconnect() async {
        await connection?.close()
        connection = nil
    }
}
