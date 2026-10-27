import Foundation

/// This Mac's host, reached directly (#1118): over agentsd's socket in the app group the
/// App Store window shares with Agents Host, not out to the control plane and back. It is
/// quicker, and it works with the control plane away.
///
/// The control plane stays the authority for who may connect. The host lets in only a
/// window its control plane lists as paired, and the window proves its key with the
/// control plane's own exchange (hello, auth, ok), with the host's key in place of the
/// control plane's. The host's `ok` names it, so a socket that is not the host this link
/// is for is never used. Agentsd's side is `Go/internal/agentsd/localpath.go`.
public struct LocalHostLink: DaemonLink {
    /// The app group both apps are entitled to: team-prefixed, so no provisioning profile.
    public static let group = "6T4RVD5724.com.alexecollins.agents"
    /// What both MACs bind on the local socket (agentsd's `localOrigin`).
    static let origin = "local:agentsd"
    /// How long each line of the exchange may take. The host is on this Mac.
    static let patience = 5.0

    /// The socket's name in the group: 12 hex digits of the SHA-256 of the control plane's
    /// key (agentsd's `LocalSocketName`), so a scratch control plane's host has its own.
    public static func socketName(controlKey: Data) -> String {
        ControlAgreement.sha256(controlKey).prefix(6).map { String(format: "%02x", $0) }.joined() + ".sock"
    }

    public let socket: URL
    public let client: UUID
    let privateKey: Data
    /// The host this link is for; a socket that names another is not used.
    public let host: MachineRef

    public init(socket: URL, client: UUID, privateKey: Data, host: MachineRef) {
        self.socket = socket
        self.client = client
        self.privateKey = privateKey
        self.host = host
    }

    public func transport() async throws -> any LineTransport {
        let reader = PrefixReader(FDTransport(socket: try connectUnixSocket(path: socket.path)))
        do {
            guard let line = try await reader.next(within: Self.patience),
                  case .hello(let hello)? = ControlAuth.Message(line: line),
                  let hostKey = ControlCode.data(base64url: hello.control) else {
                throw ControlAuth.Refusal(.badMessage)
            }
            // The host names itself in its hello: another host is left at once, before any
            // proof (#1497). `.mac`'s client, with a control plane elsewhere where this Mac's
            // host has an id of its own, tries here at each reconnect, and each proof was a
            // connection the host counted. `ok` still decides, once proved.
            guard hello.name == host.rawValue else { throw DaemonClient.ConnectError.couldNotConnect }
            let key = try ControlAuth.clientKey(privateKey: privateKey, peer: hostKey, client: client)
            let (auth, expect) = try ControlAuth.answer(hello, identity: .client(client), key: key, origin: Self.origin,
                                                        kind: ClientRecord.Kind.mac.rawValue, expecting: nil)
            try reader.write(line: ControlAuth.Message.auth(auth).line)
            guard let reply = try await reader.next(within: Self.patience), let message = ControlAuth.Message(line: reply) else {
                throw ControlAuth.Refusal(.badMessage)
            }
            switch message {
            case .ok(let ok):
                try ControlAuth.check(ok, expect: expect)
                guard ok.host == host else { throw DaemonClient.ConnectError.couldNotConnect }
                return reader
            case .refused(let reason):
                throw ControlAuth.Refusal(reason)
            default:
                throw ControlAuth.Refusal(.badMessage)
            }
        } catch {
            reader.close()
            throw error
        }
    }
}

/// A host's link that tries the direct local path first, and the control plane's route
/// when there is no local socket, or the host there refuses (#1118). Each new transport
/// tries again, so a window that fell back comes back the next time it connects, and a
/// window on the local path keeps working when the control plane goes.
public struct LocalFirstLink: DaemonLink {
    public let local: LocalHostLink?
    public let fallback: any DaemonLink
    /// Told, after each connect, whether it went the local way.
    let went: @Sendable (_ direct: Bool) -> Void

    public init(local: LocalHostLink?, fallback: any DaemonLink, went: @escaping @Sendable (_ direct: Bool) -> Void = { _ in }) {
        self.local = local
        self.fallback = fallback
        self.went = went
    }

    public func transport() async throws -> any LineTransport {
        if let local, let direct = try? await local.transport() {
            went(true)
            return direct
        }
        let through = try await fallback.transport()
        went(false)
        return through
    }

    public func start() async throws { try await fallback.start() }
    public var startsSomething: Bool { fallback.startsSomething }
}
