import Foundation

/// The Remote's own connection to the control plane's home host, wrapped as every other
/// client's is (#3234): `{"h":<home>,"m":…}` for the home host, `{"m":…}` for the control
/// plane's own methods.
///
/// Before this the Remote wrote bare JSON-RPC lines, and the control plane had to keep a
/// path for them (#3225). The phone does not know the home host's id when it dials, so
/// each connection asks `control/status` first and holds what its client writes until the
/// answer comes. A request for a method of `control.openrpc.json` goes to the control
/// plane, as a bare line did; everything else goes to the home host.
///
/// What it hands back is what a bare connection heard: the home host's lines and the
/// answers to the control plane's own methods. The control plane's notifications are for
/// the other connection (`ControlLink`); the one that says the home host went ends this
/// connection, as the control plane ended a bare one, so its client dials again.
public struct HomeLink: DaemonLink {
    public let base: any DaemonLink

    public init(_ base: any DaemonLink) {
        self.base = base
    }

    public func transport() async throws -> any LineTransport {
        Wrapped(physical: try await base.transport())
    }

    public func start() async throws { try await base.start() }

    public var startsSomething: Bool { base.startsSomething }

    /// The control plane said it has no home host, so nothing on this connection can be
    /// answered.
    public struct NoHomeHost: Error, Equatable {}

    /// The id of the `control/status` request each connection starts with: a string, so it
    /// is never one of its client's numbers.
    static let statusID = JSONRPCID.string("home-link/status")

    /// The line each connection starts with.
    public static var statusLine: String {
        ControlWire.wrap(host: nil, message: (try? JSONRPCCodec.encode(
            .request(id: statusID, method: DaemonAPI.Method.controlStatus, params: nil))) ?? "")
    }

    /// Whether a line from the client is a request the control plane answers itself.
    static func isControls(_ line: String) -> Bool {
        guard let request = ControlWire.request(in: line) else { return false }
        return Capability.control[request.method] != nil
    }

    final class Wrapped: LineTransport, ReasonedClose, @unchecked Sendable {
        private let physical: any LineTransport
        private let stream: AsyncThrowingStream<String, any Error>
        private let continuation: AsyncThrowingStream<String, any Error>.Continuation
        private let lock = NSLock()
        private var home: MachineRef?
        /// What the client wrote for the home host before its id was known.
        private var held: [String] = []
        private var closed = false

        init(physical: any LineTransport) {
            self.physical = physical
            var c: AsyncThrowingStream<String, any Error>.Continuation!
            self.stream = AsyncThrowingStream(bufferingPolicy: .unbounded) { c = $0 }
            self.continuation = c
            Task.detached { [weak self] in
                do {
                    for try await line in physical.lines() { self?.deliver(line) }
                    self?.end(nil)
                } catch {
                    self?.end(error)
                }
            }
            try? physical.write(line: HomeLink.statusLine)
        }

        func write(line: String) throws {
            if HomeLink.isControls(line) {
                guard !lock.withLock({ closed }) else { throw JSONRPCTransportError.closed }
                try physical.write(line: ControlWire.wrap(host: nil, message: line))
                return
            }
            // Under the lock, so nothing overtakes what was held.
            try lock.withLock {
                guard !closed else { throw JSONRPCTransportError.closed }
                guard let home else { return held.append(line) }
                try physical.write(line: ControlWire.wrap(host: home, message: line))
            }
        }

        func lines() -> AsyncThrowingStream<String, any Error> { stream }

        func close() {
            end(nil)
            physical.close()
        }

        func close(code: UInt16, reason: String) {
            end(nil)
            physical.close(code: code, reason: reason)
        }

        private func deliver(_ line: String) {
            let frame: ControlWire.ClientFrame
            do {
                frame = try ControlWire.readClient(line)
            } catch {
                WireLog.write("home link: unreadable frame from the control plane (\(error)): \(WireLog.excerpt(line))")
                return
            }
            switch frame {
            case .toHost(let host, let message):
                if host == lock.withLock({ home }) { continuation.yield(message) }
            case .bare(let message):
                continuation.yield(message)
            case .toControl(let message):
                guard let decoded = try? JSONRPCCodec.decode(line: message) else { return }
                switch decoded {
                case .success(HomeLink.statusID, let result):
                    guard let id = result["homeHost"]?.stringValue else { return fail(NoHomeHost()) }
                    found(MachineRef(rawValue: id))
                case .failure(HomeLink.statusID?, let error):
                    fail(error)
                case .notification(let method, let params):
                    // The home host gone: this connection ends, so its client dials again.
                    guard method == DaemonAPI.Notification.controlHostChanged,
                          let host = params?["host"]?.stringValue, host == lock.withLock({ home })?.rawValue,
                          let state = params?["state"]?.stringValue,
                          !DaemonAPI.ControlMachine.answers(state), state != "connecting" else { return }
                    close()
                case .success, .failure, .request:
                    continuation.yield(message)
                }
            }
        }

        private func found(_ host: MachineRef) {
            do {
                try lock.withLock {
                    home = host
                    defer { held = [] }
                    for line in held { try physical.write(line: ControlWire.wrap(host: host, message: line)) }
                }
            } catch {
                fail(error)
            }
        }

        private func fail(_ error: any Error) {
            end(error)
            physical.close()
        }

        private func end(_ error: (any Error)?) {
            let first = lock.withLock {
                defer { closed = true; held = [] }
                return !closed
            }
            guard first else { return }
            continuation.finish(throwing: error)
        }
    }
}
