import AgentsKitCore
import Foundation

/// The control plane, assembled (058): its records, its own methods, the router, and the
/// two local sockets this Mac's window and this Mac's host reach it on.
///
/// Devices on the network and in iCloud still reach this Mac's host through the bridge
/// as they always have; they move onto the router in US4. Hosts elsewhere join in US3.
public final class ControlPlane: @unchecked Sendable {
    public let root: URL
    public let router: ControlRouter
    public let methods: ControlMethods
    private var listeners: [UnixSocketListener] = []

    /// `~/Library/Application Support/Agents Control` on a Mac; `~/.agents-control`
    /// elsewhere. `--control-root` or `AGENTS_CONTROL_ROOT` for any other.
    public static var defaultRoot: URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Agents Control", isDirectory: true)
        #else
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agents-control", isDirectory: true)
        #endif
    }

    public static let rootVariable = "AGENTS_CONTROL_ROOT"
    public static let rootFlag = "--control-root"

    public static func chosenRoot(arguments: [String] = CommandLine.arguments,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let at = arguments.firstIndex(of: rootFlag), arguments.indices.contains(at + 1) {
            return URL(fileURLWithPath: arguments[at + 1], isDirectory: true)
        }
        return environment[rootVariable].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Where this Mac's window connects.
    public static func clientSocket(root: URL) -> URL { root.appendingPathComponent("control.sock") }
    /// Where this Mac's host connects.
    public static func hostSocket(root: URL) -> URL { root.appendingPathComponent("hosts.sock") }

    /// The name the window's record has, so every launch of it is one client.
    public static let windowName = "This Mac"

    public init(root: URL, version: String) {
        self.root = root
        let store = GrantStore(root: root)
        let settings = store.loadSettings()
            ?? ControlSettings(name: Host.current().localizedName ?? "This Mac", machineID: MachineID.current)
        try? store.saveSettings(settings)
        let methods = ControlMethods(store: store, settings: settings, version: version)
        self.methods = methods
        self.router = ControlRouter(handler: methods, knownHosts: store.loadHosts().map(\.id),
                                    homeHost: settings.homeHost)
    }

    public func start() async throws {
        await methods.attach(router)
        let roles = RolePolicy.forControl(root: root)
        DaemonLog.shared.write("control: \(roles.summary)")
        let clients = UnixSocketListener(url: Self.clientSocket(root: root), roles: roles) { [weak self] transport, role, peer in
            Task { await self?.clientArrived(transport, role: role, peer: peer) }
        }
        let hosts = UnixSocketListener(url: Self.hostSocket(root: root), roles: roles) { [weak self] transport, role, peer in
            Task { await self?.hostArrived(transport, role: role, peer: peer) }
        }
        try clients.start()
        try hosts.start()
        listeners = [clients, hosts]
        DaemonLog.shared.write("control: listening at \(root.path)")
    }

    public func stop() {
        for listener in listeners { listener.stop() }
    }

    /// This Mac's window: an operator, because only the app is `control` by signature.
    private func clientArrived(_ transport: FDTransport, role: ConnectionRole, peer: Int32?) async {
        guard role == .control else {
            DaemonLog.shared.write("control: refused a client socket connection from pid \(peer.map(String.init) ?? "?") (\(role.rawValue))")
            transport.close()
            return
        }
        let existing = await methods.allClients.first { $0.kind == .mac && $0.name == Self.windowName }
        let record = existing ?? ClientRecord(id: UUID(), name: Self.windowName, kind: .mac, publicKey: Data(),
                                              grant: .operator, paired: Date())
        try? await methods.admit(record)
        await router.attachClient(await methods.client(record.id) ?? record, transport: transport)
    }

    /// This Mac's host. Its first line is `host/hello`, which says which host it is.
    private func hostArrived(_ transport: FDTransport, role: ConnectionRole, peer: Int32?) async {
        guard role == .agent || role == .control else {
            DaemonLog.shared.write("control: refused a host socket connection from pid \(peer.map(String.init) ?? "?") (\(role.rawValue))")
            transport.close()
            return
        }
        let rest = Remainder(transport)
        guard let first = await rest.first(),
              case .message(0, let message)? = try? ControlWire.readHost(first),
              case .request(let id, DaemonAPI.Method.hostHello, let params)? = try? JSONRPCCodec.decode(line: message),
              let hello = try? params?.decode(DaemonAPI.HostHello.self),
              let host = hello.host, ControlWire.isHostID(host.rawValue) else {
            DaemonLog.shared.write("control: a host connected without saying which it is; closing it")
            transport.close()
            return
        }
        await router.attachHost(host, transport: rest)
        let reply: JSONRPCMessage
        do {
            reply = .success(id: id, result: try await methods.hostSaid(host, method: DaemonAPI.Method.hostHello, params: params))
        } catch let error as JSONRPCError {
            reply = .failure(id: id, error: error)
        } catch {
            reply = .failure(id: id, error: .internalError("\(error)"))
        }
        if let line = try? JSONRPCCodec.encode(reply) { try? rest.write(line: ControlWire.channel(0, message: line)) }
        DaemonLog.shared.write("control: host \(host) connected (\(hello.platform), \(hello.version))")
    }

    /// A transport whose first line has been read here and whose rest is read by the
    /// router: a stream is read by one reader, so this is that reader for both.
    final class Remainder: LineTransport, @unchecked Sendable {
        private let base: any LineTransport
        private let stream: AsyncThrowingStream<String, any Error>
        private let continuation: AsyncThrowingStream<String, any Error>.Continuation
        private let firstLine: AsyncStream<String?>
        private let firstContinuation: AsyncStream<String?>.Continuation

        init(_ base: any LineTransport) {
            self.base = base
            var c: AsyncThrowingStream<String, any Error>.Continuation!
            stream = AsyncThrowingStream(bufferingPolicy: .unbounded) { c = $0 }
            continuation = c
            var f: AsyncStream<String?>.Continuation!
            firstLine = AsyncStream { f = $0 }
            firstContinuation = f
            Task { [continuation, firstContinuation] in
                var sawFirst = false
                do {
                    for try await line in base.lines() {
                        if sawFirst { continuation.yield(line) } else {
                            sawFirst = true
                            firstContinuation.yield(line)
                            firstContinuation.finish()
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                if !sawFirst { firstContinuation.yield(nil); firstContinuation.finish() }
            }
        }

        func first() async -> String? {
            for await line in firstLine { return line }
            return nil
        }

        func write(line: String) throws { try base.write(line: line) }
        func lines() -> AsyncThrowingStream<String, any Error> { stream }
        func close() { base.close() }
    }
}
