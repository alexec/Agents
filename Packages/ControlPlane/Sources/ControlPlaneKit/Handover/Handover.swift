import AgentsKitCore
import ControlDial
import Foundation

/// Handing a running control plane over from one copy to another, on another machine
/// (058, research R16, #61): announce, freeze, copy, take over, forward.
///
/// Both copies hold the control plane's key; the one driving the handover (Agents Host,
/// or `agents-control handover` on the command line) proves it as a copy with the
/// identity `x:handover-<id>`, and talks to each copy over that session. Members are never
/// part of it: they follow the list of endpoints every `ok` carries.
public enum Handover {
    /// The copy identity a handover's session uses, after `x:`.
    public static let prefix = "handover-"

    public enum Phase: String, Codable, Sendable {
        /// Answering members, as always.
        case serving
        /// Started empty with `--receive`: only a handover's session is answered.
        case receiving
        /// Records may not change: the store is being copied away.
        case frozen
        /// Handed over: every member is told the new list in `ok`, then let go.
        case forwarding
    }

    public enum Method {
        public static let status = "handover/status"
        public static let announce = "handover/announce"
        public static let withdraw = "handover/withdraw"
        public static let freeze = "handover/freeze"
        public static let unfreeze = "handover/unfreeze"
        public static let forward = "handover/forward"
        public static let take = "handover/take"
        public static let stop = "handover/stop"
        public static let list = "store/list"
        public static let get = "store/get"
        public static let put = "store/put"
    }

    /// What a copy says of itself, for the one driving to check before each step.
    public struct Status: Codable, Sendable, Equatable {
        public var phase: Phase
        public var controlKey: Data
        /// Whether its store holds a control plane's records yet.
        public var hasRecords: Bool
        public var endpoints: [ControlEndpoint]
        public var epoch: Int?
        /// Members and the epoch each has said it holds, so the driver can say who has
        /// heard of the new place (nil: a build that keeps no list).
        public var members: [Member]
        /// While forwarding: when it stops (Alex: 30 days at most, T126).
        public var forwardingUntil: Date?

        public struct Member: Codable, Sendable, Equatable {
            public var id: String
            public var name: String
            public var kind: String
            public var knownEpoch: Int?
            public var version: String?
            /// Connected to this copy now. One that is, and still holds an older list, is a
            /// build that can't follow.
            public var online: Bool?
            public var lastSeen: Date?

            /// Whether it holds the list of `epoch` or a newer one.
            public func knows(_ epoch: Int?) -> Bool {
                guard let epoch else { return true }
                return (knownEpoch ?? 0) >= epoch
            }
        }
    }

    // MARK: The copy's side

    /// Answers one handover session until it closes.
    static func session(_ reader: PrefixReader, service: ControlService) async {
        defer { reader.close() }
        do {
            for try await line in reader.lines() {
                guard case .request(let id, let method, let params)? = try? JSONRPCCodec.decode(line: line) else { continue }
                let reply: JSONRPCMessage
                do {
                    reply = .success(id: id, result: try await answer(method, params, service: service))
                } catch let error as JSONRPCError {
                    reply = .failure(id: id, error: error)
                } catch let error as StoreError {
                    reply = .failure(id: id, error: error.rpcError)
                } catch {
                    reply = .failure(id: id, error: JSONRPCError(code: JSONRPCError.internalError, message: "\(error)"))
                }
                try reader.write(line: JSONRPCCodec.encode(reply))
            }
        } catch {}
    }

    private static func refuse(_ message: String) -> JSONRPCError {
        JSONRPCError(code: JSONRPCError.invalidRequest, message: message)
    }

    private static func answer(_ method: String, _ params: JSONValue?, service: ControlService) async throws -> JSONValue {
        let store = service.configuration.store
        let phase = service.phase.now
        switch method {
        case Method.status:
            return try JSONValue.encoding(await status(service))

        case Method.list:
            guard phase != .serving else { throw refuse("Freeze this copy before reading its store.") }
            let prefix = params?["prefix"]?.stringValue ?? "v1/"
            let keys = try await store.list(prefix: prefix)
            return .array(keys.map { ["key": .string($0.key), "etag": .string($0.etag)] })

        case Method.get:
            guard phase != .serving else { throw refuse("Freeze this copy before reading its store.") }
            guard let key = params?["key"]?.stringValue else { throw refuse("Say which key.") }
            guard let object = try await store.get(key) else { return .null }
            return ["data": .string(object.data.base64EncodedString()), "etag": .string(object.etag)]

        case Method.put:
            // Create only, and only into a copy that is receiving.
            guard phase == .receiving else { throw refuse("Only a receiving copy takes records.") }
            guard let key = params?["key"]?.stringValue, key.hasPrefix("v1/"),
                  let text = params?["data"]?.stringValue, let data = Data(base64Encoded: text) else {
                throw refuse("Say the key and the data.")
            }
            return .string(try await store.put(key, data, when: .absent))

        case Method.announce:
            // The new place goes after the ones members have now (R16 step 2).
            guard phase == .serving else { throw refuse("Announce from a copy that is serving.") }
            let endpoint = try params?["endpoint"]?.decode(ControlEndpoint.self)
            guard let endpoint, endpoint.isAcceptable else { throw refuse("Say the new place: https, with a pin or none.") }
            var list = await service.methods.controlSettings.currentEndpoints.filter { $0.url != endpoint.url }
            list.append(endpoint)
            try await changeEndpoints(list, service: service)
            return try JSONValue.encoding(await status(service))

        case Method.withdraw:
            // Back to answering only here, as if nothing had been announced.
            guard phase == .serving || phase == .frozen else { throw refuse("Nothing to withdraw here.") }
            try await changeEndpoints([own(service)], service: service)
            await service.methods.setFrozen(false)
            service.phase.set(.serving)
            return try JSONValue.encoding(await status(service))

        case Method.freeze:
            guard phase == .serving else { throw refuse("Only a serving copy freezes.") }
            await service.methods.setFrozen(true)
            service.phase.set(.frozen)
            service.log("frozen for a handover: records won't change here")
            return try JSONValue.encoding(await status(service))

        case Method.unfreeze:
            guard phase == .frozen else { throw refuse("This copy isn't frozen.") }
            await service.methods.setFrozen(false)
            service.phase.set(.serving)
            service.log("unfrozen: the handover was called off")
            return try JSONValue.encoding(await status(service))

        case Method.stop:
            // Stop Forwarding (frames T and Y): anyone still to hear pairs again.
            guard phase == .forwarding else { throw refuse("This copy isn't forwarding.") }
            service.forwardingUntil.set(Date())
            service.log("forwarding stopped")
            return try JSONValue.encoding(await status(service))

        case Method.forward:
            // Handed over (R16 step 5): only the new list, given to whoever still comes.
            guard phase == .frozen else { throw refuse("Freeze and copy before forwarding.") }
            guard let list = try params?["endpoints"]?.decode([ControlEndpoint].self), !list.isEmpty,
                  list.allSatisfy(\.isAcceptable) else { throw refuse("Say where members go now.") }
            // Never for ever: at most 30 days (Alex, T126), or sooner if asked.
            let longest = Date().addingTimeInterval(Handover.longestForwarding)
            let until = min((try? params?["until"]?.decode(Date.self)) ?? longest, longest)
            try await changeEndpoints(list, service: service)
            service.forwardingUntil.set(until)
            service.phase.set(.forwarding)
            service.log("forwarding until \(until.formatted(.iso8601)): members are told \(list.map(\.url).joined(separator: ", "))")
            return try JSONValue.encoding(await status(service))

        case Method.take:
            // The receiving copy takes over what was copied into it (R16 step 5).
            guard phase == .receiving else { throw refuse("Only a receiving copy takes over.") }
            guard try await store.get(ControlRecords.settingsKey) != nil else {
                throw refuse("Nothing has been copied here yet.")
            }
            try await service.takeUp()
            try await service.methods.setEndpoints([own(service)])
            service.phase.set(.serving)
            await service.mesh?.start()
            service.log("took over the control plane at \(service.configuration.url.absoluteString)")
            return try JSONValue.encoding(await status(service))

        default:
            throw JSONRPCError(code: JSONRPCError.methodNotFound, message: "\(method) is not part of a handover.")
        }
    }

    /// Where this copy answers, as members should be told.
    private static func own(_ service: ControlService) -> ControlEndpoint {
        ControlEndpoint(url: service.configuration.url.absoluteString, pin: service.configuration.pin)
    }

    /// A new list under a new epoch, on every copy, and every member here reconnects for it.
    private static func changeEndpoints(_ list: [ControlEndpoint], service: ControlService) async throws {
        try await service.methods.setEndpoints(list)
        await service.announce(ControlEvent(kind: .endpointsChanged, subject: String(await service.methods.controlSettings.epoch ?? 0),
                                            at: Date(), by: "handover"))
        service.closeMembers()
    }

    private static func status(_ service: ControlService) async -> Status {
        let phase = service.phase.now
        let hasRecords = (try? await service.configuration.store.get(ControlRecords.settingsKey)) != nil
        var members: [Status.Member] = []
        if phase != .receiving {
            let connected = await service.router.connectedClients()
            for client in await service.methods.allClients {
                members.append(.init(id: client.id.uuidString, name: client.name, kind: client.kind.rawValue,
                                     knownEpoch: client.knownEpoch, online: connected.contains(client.id),
                                     lastSeen: client.lastSeen))
            }
            for host in await service.methods.allHosts {
                members.append(.init(id: host.id.rawValue, name: host.name, kind: host.relay == nil ? "host" : "relay",
                                     knownEpoch: host.knownEpoch, version: host.version,
                                     online: await service.router.state(of: host.id)?.isOnline == true))
            }
        }
        let settings = await service.methods.controlSettings
        return Status(phase: phase, controlKey: service.publicKey, hasRecords: hasRecords,
                      endpoints: phase == .receiving ? [] : settings.currentEndpoints,
                      epoch: phase == .receiving ? nil : settings.epoch, members: members,
                      forwardingUntil: phase == .forwarding ? service.forwardingUntil.now : nil)
    }

    // MARK: The driver's side

    /// A handover session with one copy: dialled and proved with the control plane's key.
    public actor Link {
        private let reader: PrefixReader
        private var nextID = 1

        public init(_ url: URL, pin: String?, privateKey: Data) async throws {
            let credentials = ControlAuth.Credentials(
                identity: .copy(prefix + String(UUID().uuidString.prefix(8)).lowercased()),
                key: ControlAuth.copyKey(controlPrivateKey: privateKey), kind: "copy",
                controlKey: try ControlAgreement.publicKey(privateKey: privateKey))
            reader = try await ControlJoin.dial(url, pin: pin, as: credentials)
        }

        public func call(_ method: String, _ params: JSONValue = [:]) async throws -> JSONValue {
            let id = nextID
            nextID += 1
            try reader.write(line: JSONRPCCodec.encode(.request(id: .number(id), method: method, params: params)))
            while true {
                guard let line = try await reader.next(within: 60) else {
                    throw ControlService.Failure("the copy stopped answering")
                }
                switch try JSONRPCCodec.decode(line: line) {
                case .success(.number(id), let result): return result
                case .failure(.number(id), let error): throw error
                default: continue
                }
            }
        }

        public func status() async throws -> Status { try await call(Method.status).decode(Status.self) }

        public func close() { reader.close() }
    }
}

/// A copy's store, read and written over a handover session (R16 step 4), so `StoreCopy`
/// can run between two machines: reading from a frozen copy, writing into a receiving one.
public struct PeerStore: ControlStore {
    let link: Handover.Link

    public init(_ link: Handover.Link) { self.link = link }

    public func get(_ key: String) async throws -> StoredObject? {
        let reply = try await link.call(Handover.Method.get, ["key": .string(key)])
        guard let text = reply["data"]?.stringValue, let data = Data(base64Encoded: text),
              let etag = reply["etag"]?.stringValue else { return nil }
        return StoredObject(data: data, etag: etag)
    }

    public func put(_ key: String, _ data: Data, when: StoreCondition) async throws -> String {
        guard when == .absent else { throw StoreError.unavailable("a handover only creates records") }
        do {
            let reply = try await link.call(Handover.Method.put, ["key": .string(key), "data": .string(data.base64EncodedString())])
            return reply.stringValue ?? ""
        } catch let error as JSONRPCError where error.code == StoreError.conflict(key: key).rpcError.code {
            throw StoreError.conflict(key: key)
        }
    }

    public func delete(_ key: String) async throws {
        throw StoreError.unavailable("a handover never deletes")
    }

    public func list(prefix: String) async throws -> [StoredKey] {
        let reply = try await link.call(Handover.Method.list, ["prefix": .string(prefix)])
        guard case .array(let entries) = reply else { return [] }
        return entries.compactMap { entry in
            guard let key = entry["key"]?.stringValue, let etag = entry["etag"]?.stringValue else { return nil }
            return StoredKey(key: key, etag: etag)
        }
    }
}

extension Handover {
    /// The longest a copy forwards (Alex, 2026-10-01): anyone still to hear after that
    /// pairs again.
    public static let longestForwarding: TimeInterval = 30 * 24 * 3600
}

/// When a forwarding copy stops; read on any thread.
final class DateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date?
    var now: Date? { lock.withLock { value } }
    func set(_ new: Date?) { lock.withLock { value = new } }
}

/// Where a copy is in a handover; read on any thread.
final class PhaseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Handover.Phase
    init(_ value: Handover.Phase) { self.value = value }
    var now: Handover.Phase { lock.withLock { value } }
    func set(_ new: Handover.Phase) { lock.withLock { value = new } }
}

extension ControlService {
    /// Every member's socket here closes, so each reconnects and is given the list.
    func closeMembers() { sockets.closeAll() }
}
