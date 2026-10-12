import AgentsKitCore
import Foundation

/// Prompts and agent starts for a stopped workspace, kept until its host connects (#691 US3,
/// research R9).
///
/// A request is kept in the store at `v1/kept/<host>/<seq>.json`, so it outlives the client
/// that sent it and a restart of the control plane (US3 AS2). The workspace is started, and
/// when the host attaches what was kept goes in order, each on a channel bound to the client
/// that sent it, and is deleted once the host has answered. Each is sent with an id of its
/// own (`sendID`, `requestID`) that the host dedupes, so sending one twice does it once.
public actor KeptRequests: KeptHandling {
    /// What it needs of the workspace part: whether a host's requests are kept, and to start it.
    public struct Hooks: Sendable {
        /// The host's name when its workspace is stopped or starting and starts when used;
        /// nil when its requests are refused as today.
        public var keepable: @Sendable (HostID) async -> String?
        /// Starts the host's workspace, or joins the start under way, for `by`.
        public var start: @Sendable (HostID, String) async -> Void

        public init(keepable: @escaping @Sendable (HostID) async -> String?,
                    start: @escaping @Sendable (HostID, String) async -> Void) {
            self.keepable = keepable
            self.start = start
        }
    }

    /// As it is stored: the request itself, and who sent it.
    struct Record: Codable, Sendable {
        var id: UUID
        var host: HostID
        var method: String
        var params: JSONValue?
        var client: UUID
        var clientKind: ClientRecord.Kind
        var at: Date
        var failed: String?
    }

    public static let prefix = "v1/kept/"
    /// At most this many per host (spec, edge cases).
    public static let limit = 20

    private let store: any ControlStore
    private let router: ControlRouter
    private let hooks: Hooks
    private let log: @Sendable (String) -> Void
    /// Each host's kept requests, in order, with their keys.
    private var kept: [HostID: [(key: String, record: Record)]] = [:]
    private var delivering: Set<HostID> = []
    private var loaded = false

    public init(store: any ControlStore, router: ControlRouter, hooks: Hooks,
                log: @escaping @Sendable (String) -> Void) {
        self.store = store
        self.router = router
        self.hooks = hooks
        self.log = log
    }

    /// Reads what was kept before a restart.
    public func load() async {
        guard !loaded else { return }
        loaded = true
        guard let keys = try? await store.list(prefix: Self.prefix) else { return }
        for key in keys.map(\.key).sorted() {
            guard let object = try? await store.get(key),
                  let record = try? ControlRecords.decoder.decode(Record.self, from: object.data) else { continue }
            kept[record.host, default: []].append((key, record))
        }
    }

    // MARK: KeptHandling

    public func keep(host: HostID, method: String, params: JSONValue?, from caller: ControlRouter.Caller) async -> JSONRPCError? {
        await load()
        guard DaemonAPI.Method.keptMethods.contains(method), let name = await hooks.keepable(host) else { return nil }
        let waiting = kept[host, default: []].filter { $0.record.failed == nil }
        guard waiting.count < Self.limit else {
            return JSONRPCError(code: DaemonAPI.Failure.hostOffline,
                                message: "\(name) is starting; too many prompts are waiting.")
        }
        let record = Record(id: UUID(), host: host, method: method, params: Self.once(method, params),
                            client: caller.client, clientKind: caller.kind, at: Date())
        let key = Self.prefix + host.rawValue + "/" + Self.sequence(record.at) + "-" + record.id.uuidString + ".json"
        do {
            _ = try await store.put(key, try ControlRecords.encoder.encode(record), when: .absent)
        } catch {
            return JSONRPCError(code: DaemonAPI.Failure.storeUnavailable,
                                message: "\(name) is stopped, and the control plane couldn’t keep this to send later.")
        }
        kept[host, default: []].append((key, record))
        log("workspace: kept \(record.kind) for \(name) from client \(caller.client.uuidString.prefix(8).lowercased())")
        await changed()
        await hooks.start(host, "kept \(record.kind)")
        // It may have come up while this was being written.
        if await router.state(of: host)?.isOnline == true { Task { await self.attached(host) } }
        return JSONRPCError(code: DaemonAPI.Failure.kept,
                            message: "\(name) is starting. This is sent when it connects.",
                            data: try? JSONValue.encoding(Self.summary(record)))
    }

    public func attached(_ host: HostID) async {
        await load()
        guard !delivering.contains(host) else { return }
        delivering.insert(host)
        defer { delivering.remove(host) }
        while let next = kept[host]?.first(where: { $0.record.failed == nil }) {
            let record = next.record
            guard let reply = await router.deliverKept(record.method, params: record.params, as: record.client,
                                                       kind: record.clientKind, to: host) else {
                // Gone again before it answered, or not answering: it stays for next time.
                return
            }
            switch reply {
            case .success(_, let result):
                await remove(host, record.id)
                log("workspace: delivered kept \(record.kind) to \(host)")
                let agent = record.method == DaemonAPI.Method.agentsStart ? try? result.decode(UUID.self) : nil
                if let said = try? JSONValue.encoding(DaemonAPI.KeptDelivered(host: host, id: record.id, agentID: agent)) {
                    await router.broadcastControl(DaemonAPI.Notification.controlKeptDelivered, said)
                }
            case .failure(_, let error):
                // The host said no (its folder has gone, say): not sent, in its words.
                log("workspace: kept \(record.kind) for \(host) refused: \(error.message)")
                await fail(host, only: record.id, error.message)
            case .request, .notification:
                return
            }
        }
        await changed()
    }

    // MARK: What clients and the workspace part ask

    public func all() async -> [DaemonAPI.KeptRequest] {
        await load()
        return kept.keys.sorted { $0.rawValue < $1.rawValue }.flatMap { host in
            kept[host, default: []].map { Self.summary($0.record) }
        }
    }

    public func answer(method: String, params: JSONValue?) async throws -> JSONValue {
        await load()
        switch method {
        case DaemonAPI.Method.hostsListKept:
            return try JSONValue.encoding(DaemonAPI.KeptList(kept: await all()))
        case DaemonAPI.Method.hostsDropKept:
            let which = try Self.require(params)
            await remove(which.host, which.id)
            log("workspace: dropped kept request for \(which.host)")
            await changed()
            return [:]
        case DaemonAPI.Method.hostsRetryKept:
            let which = try Self.require(params)
            guard let index = kept[which.host]?.firstIndex(where: { $0.record.id == which.id }) else {
                throw JSONRPCError(code: JSONRPCError.invalidParams, message: "That was sent or dropped already.")
            }
            var entry = kept[which.host]![index]
            entry.record.failed = nil
            _ = try? await store.put(entry.key, try ControlRecords.encoder.encode(entry.record), when: .always)
            kept[which.host]![index] = entry
            await changed()
            if await router.state(of: which.host)?.isOnline == true {
                Task { await self.attached(which.host) }
            } else {
                await hooks.start(which.host, "kept \(entry.record.kind), tried again")
            }
            return [:]
        default:
            throw JSONRPCError.methodNotFound(method)
        }
    }

    /// The start failed: every request waiting on it is shown not sent, with why (US3 AS4).
    public func startFailed(_ host: HostID, _ reason: String) async {
        await load()
        await fail(host, only: nil, reason)
        await changed()
    }

    /// A host was removed: what was kept for it goes, not sent (spec, edge cases).
    public func forget(_ host: HostID) async {
        await load()
        for entry in kept.removeValue(forKey: host) ?? [] { try? await store.delete(entry.key) }
        await changed()
    }

    // MARK: Helpers

    private func fail(_ host: HostID, only id: UUID?, _ reason: String) async {
        guard var entries = kept[host] else { return }
        for index in entries.indices where entries[index].record.failed == nil && (id == nil || entries[index].record.id == id) {
            entries[index].record.failed = reason
            _ = try? await store.put(entries[index].key, try ControlRecords.encoder.encode(entries[index].record), when: .always)
        }
        kept[host] = entries
    }

    private func remove(_ host: HostID, _ id: UUID) async {
        guard let index = kept[host]?.firstIndex(where: { $0.record.id == id }) else { return }
        let entry = kept[host]!.remove(at: index)
        if kept[host]?.isEmpty == true { kept[host] = nil }
        try? await store.delete(entry.key)
    }

    private func changed() async {
        if let said = try? JSONValue.encoding(DaemonAPI.KeptList(kept: await all())) {
            await router.broadcastControl(DaemonAPI.Notification.controlKeptChanged, said)
        }
    }

    /// The request with an id the host dedupes by, filled in when the client left it out,
    /// and without a draft runtime, which a stopped host can't have.
    static func once(_ method: String, _ params: JSONValue?) -> JSONValue? {
        guard var object = params?.objectValue else { return params }
        let key = method == DaemonAPI.Method.agentsStart ? "requestID" : "sendID"
        if object[key] == nil || object[key] == .null { object[key] = .string(UUID().uuidString) }
        if method == DaemonAPI.Method.agentsStart { object["draftID"] = nil }
        return .object(object)
    }

    static func summary(_ record: Record) -> DaemonAPI.KeptRequest {
        let object = record.params?.objectValue
        let start = record.method == DaemonAPI.Method.agentsStart
        return DaemonAPI.KeptRequest(
            id: record.id, host: record.host, kind: record.kind,
            agentID: start ? nil : object?["agentID"]?.stringValue.flatMap(UUID.init(uuidString:)),
            text: (start ? object?["prompt"] : object?["text"])?.stringValue ?? "",
            folder: start ? object?["cwd"]?.stringValue.flatMap { URL(string: $0) } : nil,
            runtimeID: start ? object?["runtimeID"]?.stringValue : nil,
            at: record.at, failed: record.failed)
    }

    /// Sorts as it was kept.
    static func sequence(_ date: Date) -> String {
        String(format: "%016.0f", (date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    private static func require(_ params: JSONValue?) throws -> DaemonAPI.KeptRequestID {
        guard let params, let value = try? params.decode(DaemonAPI.KeptRequestID.self) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "Which kept request?")
        }
        return value
    }
}

extension KeptRequests.Record {
    var kind: String { method == DaemonAPI.Method.agentsStart ? "start" : "prompt" }
}
