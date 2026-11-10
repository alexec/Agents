import Foundation

/// A bare daemon's link as a control plane with that daemon as its one host carries it
/// (#4126): `HomeLink`'s other end, for the Remote's canned daemon.
///
/// Since #3234 the Remote wraps every line as `{"h":<home>,"m":…}` and holds them all until
/// `control/status` names its home host. A daemon that reads bare JSON-RPC never answers
/// that, so the first ping waited for ever. Here the home host's lines go to the daemon
/// unwrapped and come back wrapped, `HomeLink`'s own `control/status` names `host` as home,
/// and every other request for the control plane is refused at once, as the canned daemon
/// refused it before: a client asking `control/status` itself finds no control plane, so
/// the Remote does not look for other hosts behind it.
public struct OneHostPlane: DaemonLink {
    public let daemon: any DaemonLink
    public let host: MachineRef

    public init(_ daemon: any DaemonLink, host: MachineRef = .mac) {
        self.daemon = daemon
        self.host = host
    }

    public func transport() async throws -> any LineTransport {
        let inner = try await daemon.transport()
        let (near, far) = PairedTransport.pair()
        let host = host
        Task.detached {
            do {
                for try await line in inner.lines() { try far.write(line: ControlWire.wrap(host: host, message: line)) }
            } catch {}
            far.close()
        }
        Task.detached {
            do {
                for try await line in far.lines() {
                    switch try? ControlWire.readClient(line) {
                    case .toHost(let to, let message)? where to == host: try inner.write(line: message)
                    case .bare(let message)?: try inner.write(line: message)
                    case .toControl(let message)?: try Self.answer(message, host: host).map { try far.write(line: $0) }
                    case .toHost?, nil: continue
                    }
                }
            } catch {}
            inner.close()
        }
        return near
    }

    public func start() async throws { try await daemon.start() }

    public var startsSomething: Bool { daemon.startsSomething }

    /// The control plane's answer to a request for it, wrapped; nil for a notification.
    static func answer(_ message: String, host: MachineRef) throws -> String? {
        guard let (id, method) = ControlWire.request(in: message) else { return nil }
        let reply: JSONRPCMessage = id == HomeLink.statusID && method == DaemonAPI.Method.controlStatus
            ? .success(id: id, result: .object(["homeHost": .string(host.rawValue)]))
            : .failure(id: id, error: JSONRPCError(code: -32601, message: "No control plane here: \(method)"))
        return ControlWire.wrap(host: nil, message: try JSONRPCCodec.encode(reply))
    }
}
