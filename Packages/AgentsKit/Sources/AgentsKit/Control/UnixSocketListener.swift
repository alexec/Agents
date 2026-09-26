import AgentsKitCore
import Foundation

/// A Unix socket this account alone may connect to, handing each connection on with the
/// role its code signature earns (058). The control plane has two: one for this Mac's
/// window, one for this Mac's host. The daemon's own socket works the same way; this is
/// that door without the JSON-RPC behind it, because the control plane carries lines.
public final class UnixSocketListener: @unchecked Sendable {
    public typealias Accepted = @Sendable (_ transport: FDTransport, _ role: ConnectionRole, _ peer: Int32?) -> Void

    private let url: URL
    private let roles: RolePolicy
    private let accepted: Accepted
    private var listenFD: Int32 = -1
    private let stopped = ManagedAtomicFlag()

    public init(url: URL, roles: RolePolicy, accepted: @escaping Accepted) {
        self.url = url
        self.roles = roles
        self.accepted = accepted
    }

    public func start() throws {
        let path = url.path
        guard path.utf8.count < 104 else { throw DaemonServerError.socketPathTooLong(path.utf8.count) }
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        unlink(path)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw DaemonServerError.cannotCreateSocket(errno: errno) }
        setCloseOnExec(listenFD)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, size) }
        }
        guard bound == 0 else { close(listenFD); throw DaemonServerError.cannotBind(errno: errno) }
        chmod(path, 0o600)
        guard listen(listenFD, 16) == 0 else { close(listenFD); throw DaemonServerError.cannotListen(errno: errno) }

        let listenFD = self.listenFD
        let thread = Thread { [weak self] in
            while true {
                let fd = accept(listenFD, nil, nil)
                if fd < 0 {
                    if errno == EINTR { continue }
                    return
                }
                setCloseOnExec(fd)
                guard PeerCredentials.uid(of: fd) == geteuid() else { close(fd); continue }
                DaemonServer.limitSendWait(fd)
                guard let self, !self.stopped.isSet else { close(fd); return }
                self.accepted(FDTransport(socket: fd), self.roles.role(fd), PeerCredentials.pid(of: fd))
            }
        }
        thread.name = "AgentsKit.UnixSocketListener"
        thread.start()
    }

    public func stop() {
        guard stopped.set() else { return }
        if listenFD >= 0 { close(listenFD) }
        unlink(url.path)
    }
}

public extension RolePolicy {
    /// Who may reach a control plane's local sockets: the app and the bridge as clients,
    /// `agentsd` as a host, by code signature, as the daemon decides for its own socket.
    /// A control plane not signed by a team, or on a root other than the ordinary one,
    /// is open to this account unless `AGENTS_ENFORCE_ROLES` is set, for the same
    /// reasons a scratch daemon is.
    static func forControl(root: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> RolePolicy {
        #if canImport(Security)
        guard let team = CallerSignature.ownTeam else {
            return RolePolicy(summary: "not signed by a team, so " + open.summary, role: open.role)
        }
        if root.standardizedFileURL != ControlPlane.defaultRoot.standardizedFileURL,
           environment["AGENTS_ENFORCE_ROLES"] == nil {
            return RolePolicy(summary: "a scratch control root, so " + open.summary, role: open.role)
        }
        return signatures(team: team)
        #else
        return open
        #endif
    }
}
