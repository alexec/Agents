// Not on Linux yet: a Linux control plane serves only its local sockets until spike S1
// (058, R8).
#if canImport(Network) && canImport(CryptoKit)
import AgentsKitCore
import CryptoKit
import Foundation
import Network

/// The control plane on the network (058, T018–T020): TLS with a pre-shared key per
/// paired client and enrolled host, and one per code while it is good.
///
/// The same lock the bridge puts on a phone's link (`LinkTLS`), with keys of its own
/// (`ControlKeys`). Network framework chooses among the keys a listener was made with, so
/// a client paired or forgotten, a host enrolled or removed, or a code shown or spent,
/// means a new listener on the same port. Connections the old one accepted carry on; a
/// forgotten client's are ended by the router.
public actor ControlNet {
    private let root: URL
    private let port: NWEndpoint.Port
    private let advertise: Bool
    private let chosen = ChosenIdentities()
    private let key: DeviceKey
    private weak var methods: ControlMethods?
    private weak var plane: ControlPlane?
    private var listener: NWListener?
    private var listening: Set<String>?
    /// Codes being shown, by the identity a connection holding one offers.
    private var codes: [String: (code: ControlCode, expires: Date)] = [:]

    public static let serviceType = ControlBonjour.serviceType
    public static let portVariable = "AGENTS_CONTROL_PORT"
    public static let defaultPort: UInt16 = 8791

    public init(root: URL, port: UInt16, advertise: Bool) throws {
        self.root = root
        self.port = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: Self.defaultPort)!
        self.advertise = advertise
        key = try DeviceKey.load(file: root.appendingPathComponent("control-key"))
    }

    public var publicKey: Data { key.publicKey }

    /// Whether the running listener takes `identity`, for tests and the log.
    public func listensFor(_ identity: String) -> Bool { listening?.contains(identity) ?? false }

    func attach(methods: ControlMethods, plane: ControlPlane) {
        self.methods = methods
        self.plane = plane
    }

    // MARK: Codes

    /// A fresh code for `purpose`, replacing any other of the same purpose: two sheets
    /// opened one after the other leave only the second's code working.
    public func startCode(_ purpose: ControlCode.Purpose, name: String) async -> DaemonAPI.ControlCodeShown {
        var generator = SystemRandomNumberGenerator()
        let secret = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let code = ControlCode(purpose: purpose, controlKey: key.publicKey, secret: secret,
                               addresses: addresses(), name: name)
        let expires = Date().addingTimeInterval(ControlCode.lifetime)
        codes = codes.filter { !Self.samePurpose($0.value.code.purpose, purpose) }
        codes[ControlKeys.codeIdentity(code)] = (code, expires)
        await relisten()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(ControlCode.lifetime + 1))
            await self?.expire()
        }
        return DaemonAPI.ControlCodeShown(text: code.text, expires: expires)
    }

    public func stopCodes() async {
        codes = [:]
        await relisten()
    }

    private func expire() async {
        let now = Date()
        let before = codes.count
        codes = codes.filter { $0.value.expires > now }
        if codes.count != before { await relisten() }
    }

    private static func samePurpose(_ a: ControlCode.Purpose, _ b: ControlCode.Purpose) -> Bool {
        switch (a, b) {
        case (.host, .host), (.client, .client): true
        default: false
        }
    }

    /// Where a code says to look: this Mac's name on the network, then loopback for a
    /// second window on the same Mac.
    private func addresses() -> [String] {
        let name = ProcessInfo.processInfo.hostName
        var found = [String]()
        if !name.isEmpty, name != "localhost" { found.append("\(name):\(port.rawValue)") }
        found.append("127.0.0.1:\(port.rawValue)")
        return found
    }

    // MARK: Listening

    public func start() async {
        await relisten()
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func keys() async -> [String: SymmetricKey] {
        var keys: [String: SymmetricKey] = [:]
        for client in await methods?.allClients ?? [] where !client.publicKey.isEmpty {
            if let made = try? ControlKeys.clientKey(key, peer: client.publicKey, client: client.id) {
                keys[ControlKeys.clientIdentity(client.id)] = made
            }
        }
        for host in await methods?.allHosts ?? [] {
            guard let publicKey = host.publicKey,
                  let made = try? ControlKeys.hostKey(key, peer: publicKey, host: host.id) else { continue }
            keys[ControlKeys.hostIdentity(host.id)] = made
        }
        for (identity, held) in codes where held.expires > Date() {
            keys[identity] = ControlKeys.codeKey(held.code.secret)
        }
        return keys
    }

    /// Called whenever who may connect has changed.
    public func relisten() async {
        let keys = await keys()
        guard Set(keys.keys) != listening else { return }
        listening = Set(keys.keys)
        if let old = listener {
            listener = nil
            old.stateUpdateHandler = { [weak self] state in
                guard case .cancelled = state else { return }
                Task { await self?.listen() }
            }
            old.cancel()
        } else {
            listen(with: keys)
        }
    }

    private func listen() async {
        listen(with: await keys())
    }

    private func listen(with keys: [String: SymmetricKey]) {
        listening = Set(keys.keys)
        guard listener == nil else { return }
        // A listener with no key at all takes nobody, and Network refuses to make one.
        guard !keys.isEmpty else { return }
        do {
            let parameters = LinkTLS.server(keys: keys, chosen: chosen)
            parameters.allowLocalEndpointReuse = true
            let made = try NWListener(using: parameters, on: port)
            if advertise {
                made.service = NWListener.Service(name: Host.current().localizedName ?? "Control plane",
                                                  type: Self.serviceType)
            }
            made.newConnectionHandler = { [weak self] connection in
                Task { await self?.accepted(connection) }
            }
            let port = self.port
            made.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    DaemonLog.shared.write("control: listening on port \(port) with TLS for \(keys.count) key(s)")
                case .failed(let error):
                    DaemonLog.shared.write("control: could not listen on \(port): \(error); trying again")
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        await self?.retry()
                    }
                default:
                    break
                }
            }
            made.start(queue: .global())
            listener = made
        } catch {
            DaemonLog.shared.write("control: could not listen on \(port): \(error)")
        }
    }

    private func retry() async {
        listener = nil
        listening = nil
        await relisten()
    }

    // MARK: A connection

    private func accepted(_ connection: NWConnection) async {
        let transport = NWTransport(connection: connection)
        do {
            try await transport.waitUntilReady()
        } catch {
            transport.close()
            return
        }
        guard LinkTLS.agreedTheSuite(connection), let identity = chosen.take(for: connection),
              let who = ControlKeys.read(identity) else {
            DaemonLog.shared.write("control: a connection's key could not be told; closing it")
            transport.close()
            return
        }
        switch who {
        case .client(let id):
            guard let methods, let plane, let record = await methods.client(id) else { transport.close(); return }
            try? await methods.admit(record)
            await plane.router.attachClient(await methods.client(id) ?? record, transport: transport)
            DaemonLog.shared.write("control: client \(record.name) connected over the network")
        case .host(let id):
            await plane?.hostArrived(transport, as: id)
        case .pairing(let identity), .enrolling(let identity):
            await admit(transport, holding: identity)
        }
    }

    /// Someone holding a code says who they are, once, and hangs up (T020, T029).
    private func admit(_ transport: NWTransport, holding identity: String) async {
        defer { transport.close() }
        guard let held = codes[identity], held.expires > Date(), let methods else { return }
        var lines = transport.lines().makeAsyncIterator()
        guard let line = try? await lines.next(),
              case .request(let id, let method, let params)? = try? JSONRPCCodec.decode(line: line) else { return }
        let reply: JSONRPCMessage
        do {
            let admitted: DaemonAPI.Admitted
            switch (held.code.purpose, method) {
            case (.client(let grant), DaemonAPI.Method.clientsAnnounce):
                guard let announce = try? params?.decode(DaemonAPI.ClientAnnounce.self) else {
                    throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Say who you are.")
                }
                try await methods.admit(ClientRecord(id: announce.id, name: announce.name, kind: announce.kind,
                                                     publicKey: announce.publicKey, grant: grant, paired: Date()))
                admitted = DaemonAPI.Admitted(client: announce.id, grant: grant)
                DaemonLog.shared.write("control: \(announce.name) paired as \(grant.rawValue)")
            case (.host, DaemonAPI.Method.hostsAnnounce):
                guard let announce = try? params?.decode(DaemonAPI.HostAnnounce.self) else {
                    throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Say which host you are.")
                }
                let host = HostID.make()
                try await methods.enroll(HostRecord(id: host, name: announce.name, publicKey: announce.publicKey,
                                                    platform: announce.platform, version: announce.version,
                                                    machineID: announce.machineID))
                await plane?.router.know(host)
                admitted = DaemonAPI.Admitted(host: host)
                DaemonLog.shared.write("control: host \(announce.name) enrolled as \(host)")
            default:
                throw JSONRPCError(code: DaemonAPI.Failure.notPermitted, message: "That code is not for \(method).")
            }
            // Good once.
            codes[identity] = nil
            reply = .success(id: id, result: try JSONValue.encoding(admitted))
        } catch let error as JSONRPCError {
            reply = .failure(id: id, error: error)
        } catch {
            reply = .failure(id: id, error: .internalError("\(error)"))
        }
        if let text = try? JSONRPCCodec.encode(reply) { try? transport.write(line: text) }
        // Let the reply leave before the connection goes.
        try? await Task.sleep(for: .milliseconds(300))
        await relisten()
    }
}
#endif
