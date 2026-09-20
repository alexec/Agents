import Foundation
@testable import AgentsKit
@testable import AgentsKitCore

/// What every surface heard about needs, in the order it was said.
///
/// It records **all** `attention/changed` notifications, not only the ones naming a
/// particular surface — the losers withdrawing is the behaviour under test, and a fake
/// that filtered would hide it. One recorder per core: `setBroadcaster` replaces the
/// core's broadcaster, so it is the daemon's whole audience.
final class AttentionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var heard: [DaemonAPI.AttentionNotification] = []

    func attach(to core: DaemonCore) async {
        await core.setBroadcaster { [weak self] method, params in
            guard method == DaemonAPI.Notification.attentionChanged, let params,
                  let notification = try? params.decode(DaemonAPI.AttentionNotification.self)
            else { return }
            self?.append(notification)
        }
    }

    private func append(_ notification: DaemonAPI.AttentionNotification) {
        lock.lock(); defer { lock.unlock() }
        heard.append(notification)
    }

    var changes: [DaemonAPI.AttentionNotification] {
        lock.lock(); defer { lock.unlock() }
        return heard
    }

    /// The ones that put a need somewhere.
    var deliveries: [DaemonAPI.AttentionNotification] { changes.filter { $0.to != nil } }
    /// The ones that took a need away everywhere.
    var withdrawals: [DaemonAPI.AttentionNotification] { changes.filter { $0.need == nil } }
}

/// A surface, as the daemon sees one: an identity taken from the connection, and
/// presence reported through the same method a window uses. It passes the identity the
/// way `DaemonServer` does — beside the request, never inside its parameters.
struct FakeSurface: Sendable {
    let connection = UUID()
    let surface: Surface

    init(_ surface: Surface = .mac) { self.surface = surface }

    /// `presence/report`, as this surface. The daemon stamps the time; this sends none.
    @discardableResult
    func report(_ core: DaemonCore, watching: UUID? = nil, active: Bool = true,
                mayNotify: Bool? = nil) async -> Result<JSONValue, JSONRPCError> {
        let params = try? JSONValue.encoding(DaemonAPI.PresenceReport(watching: watching, active: active,
                                                                       mayNotify: mayNotify))
        return await core.handle(method: DaemonAPI.Method.presenceReport, params: params,
                                 from: surface, connection: connection)
    }

    /// The connection going away, as the server reports it.
    func disconnect(_ core: DaemonCore) async {
        await core.forgetPresence(connection: connection)
    }

    /// `surface/identify`, as a device does once it is connected. The identity is
    /// passed beside the request, as the server passes it after setting it.
    @discardableResult
    func identify(_ core: DaemonCore, name: String, kind: Device.Kind) async -> Result<JSONValue, JSONRPCError> {
        guard let id = surface.deviceID else { return .failure(.internalError("not a device")) }
        let params = try? JSONValue.encoding(DaemonAPI.SurfaceIdentification(id: id, name: name, kind: kind))
        return await core.handle(method: DaemonAPI.Method.surfaceIdentify, params: params,
                                 from: surface, connection: connection)
    }
}
