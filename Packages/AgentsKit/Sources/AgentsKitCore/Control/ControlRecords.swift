import Foundation

/// The control plane's records, kept in a `ControlStore` (058, contracts/store.md,
/// data-model.md): one object per client and per host, the settings, and the one person
/// they belong to for now.
///
/// It keeps what it has read, with each object's entity tag, and every change it makes
/// is a conditional write against the version it read. Another copy's change first means
/// `StoreError.conflict`, and nothing changed here either. Forgetting writes a tombstone,
/// read as absent, because a store cannot be trusted to delete conditionally.
public actor ControlRecords {
    public static let clientsPrefix = "v1/clients/"
    public static let hostsPrefix = "v1/hosts/"
    public static let settingsKey = "v1/control.json"
    public static func clientKey(_ id: UUID) -> String { clientsPrefix + id.uuidString.lowercased() + ".json" }
    public static func hostKey(_ id: HostID) -> String { hostsPrefix + id.rawValue + ".json" }
    public static func personKey(_ id: PersonID) -> String { "v1/people/\(id.rawValue).json" }

    private struct Held<Record: Sendable>: Sendable {
        var record: Record
        var etag: String
    }

    public let store: any ControlStore
    private var clientsHeld: [UUID: Held<ClientRecord>] = [:]
    private var hostsHeld: [HostID: Held<HostRecord>] = [:]
    private var settingsHeld: Held<ControlSettings>?
    /// Tags of tombstones, so a refresh does not read them again and again.
    private var tombstones: [String: String] = [:]

    public init(store: any ControlStore) { self.store = store }

    // MARK: Reading

    /// Everything, from the store. At start-up, and as the backstop every 15 s (R4): only
    /// objects whose tag changed are read again.
    public func load() async throws {
        var clients: [UUID: Held<ClientRecord>] = [:]
        for entry in try await store.list(prefix: Self.clientsPrefix) {
            if let held = clientsHeld.values.first(where: { Self.clientKey($0.record.id) == entry.key && $0.etag == entry.etag }) {
                clients[held.record.id] = held
                continue
            }
            if tombstones[entry.key] == entry.etag { continue }
            guard let object = try await store.get(entry.key),
                  let record = try? Self.decoder.decode(ClientRecord.self, from: object.data) else { continue }
            if record.forgotten == true { tombstones[entry.key] = object.etag; continue }
            clients[record.id] = Held(record: record, etag: object.etag)
        }
        var hosts: [HostID: Held<HostRecord>] = [:]
        for entry in try await store.list(prefix: Self.hostsPrefix) {
            if let held = hostsHeld.values.first(where: { Self.hostKey($0.record.id) == entry.key && $0.etag == entry.etag }) {
                hosts[held.record.id] = held
                continue
            }
            if tombstones[entry.key] == entry.etag { continue }
            guard let object = try await store.get(entry.key),
                  let record = try? Self.decoder.decode(HostRecord.self, from: object.data) else { continue }
            if record.forgotten == true { tombstones[entry.key] = object.etag; continue }
            hosts[record.id] = Held(record: record, etag: object.etag)
        }
        clientsHeld = clients
        hostsHeld = hosts
        if let object = try await store.get(Self.settingsKey),
           let settings = try? Self.decoder.decode(ControlSettings.self, from: object.data) {
            settingsHeld = Held(record: settings, etag: object.etag)
        }
    }

    public var clients: [ClientRecord] { clientsHeld.values.map(\.record).sorted { $0.paired < $1.paired } }
    public var hosts: [HostRecord] { hostsHeld.values.map(\.record).sorted { $0.id.rawValue < $1.id.rawValue } }
    public func client(_ id: UUID) -> ClientRecord? { clientsHeld[id]?.record }
    public func host(_ id: HostID) -> HostRecord? { hostsHeld[id]?.record }
    public var settings: ControlSettings? { settingsHeld?.record }

    // MARK: Settings

    /// The settings, made once if there are none. Two copies starting on an empty store
    /// both try; the one that loses reads the winner's.
    public func settings(orMake make: @Sendable () -> ControlSettings) async throws -> ControlSettings {
        if let settings = settingsHeld?.record { return settings }
        if let object = try await store.get(Self.settingsKey),
           let settings = try? Self.decoder.decode(ControlSettings.self, from: object.data) {
            settingsHeld = Held(record: settings, etag: object.etag)
            return settings
        }
        var made = make()
        if made.owner == nil { made.owner = PersonID.make() }
        made.created = made.created ?? Date()
        made.rev = 1
        do {
            let data = try Self.encoder.encode(made)
            let etag = try await store.put(Self.settingsKey, data, when: .absent)
            made = try Self.decoder.decode(ControlSettings.self, from: data)
            settingsHeld = Held(record: made, etag: etag)
            if let owner = made.owner {
                _ = try? await store.put(Self.personKey(owner),
                                         try Self.encoder.encode(Person(id: owner, name: made.name)), when: .absent)
            }
            return made
        } catch StoreError.conflict {
            settingsHeld = nil
            return try await settings(orMake: make)
        }
    }

    /// Changes the settings against the version read.
    public func changeSettings(_ change: (inout ControlSettings) -> Void) async throws -> ControlSettings {
        guard let held = settingsHeld else { throw StoreError.unavailable("there are no settings to change yet") }
        var settings = held.record
        change(&settings)
        guard settings != held.record else { return settings }
        settings.rev = (settings.rev ?? 0) + 1
        let (kept, etag) = try await write(settings, to: Self.settingsKey, when: .matching(held.etag))
        settingsHeld = Held(record: kept, etag: etag)
        return kept
    }

    // MARK: Clients

    /// A client that paired, or one seen again: created if new, else updated against the
    /// version read.
    public func save(_ client: ClientRecord) async throws {
        var record = client
        record.owner = record.owner ?? settingsHeld?.record.owner
        let key = Self.clientKey(record.id)
        let condition: StoreCondition
        if let held = clientsHeld[record.id] {
            record.rev = held.record.rev + 1
            condition = .matching(held.etag)
        } else {
            record.rev = 1
            condition = .absent
        }
        let (kept, etag) = try await write(record, to: key, when: condition)
        clientsHeld[record.id] = Held(record: kept, etag: etag)
    }

    /// `clients/setGrant`, refused if it would leave no operator (FR-016). The check is
    /// made on the records as read; a change elsewhere in between is `conflict`.
    public func setGrant(_ grant: Grant, of id: UUID) async throws {
        // Paired at another copy since this one last read the store (US3).
        if clientsHeld[id] == nil { try await load() }
        guard var record = clientsHeld[id]?.record else {
            throw JSONRPCError(code: DaemonAPI.Failure.notAllowed, message: "No client has that id.")
        }
        record.grant = grant
        var after = clientsHeld.mapValues(\.record)
        after[id] = record
        try Self.requireOperator(in: Array(after.values))
        try await save(record)
    }

    /// `clients/forget`: a tombstone against the version read, refused for the last
    /// operator. Nothing happens for a client that is not known.
    public func forget(_ id: UUID) async throws {
        if clientsHeld[id] == nil { try await load() }
        guard let held = clientsHeld[id] else { return }
        var after = clientsHeld.mapValues(\.record)
        after[id] = nil
        try Self.requireOperator(in: Array(after.values))
        var tombstone = held.record
        tombstone.forgotten = true
        tombstone.rev += 1
        let etag = try await store.put(Self.clientKey(id), try Self.encoder.encode(tombstone), when: .matching(held.etag))
        tombstones[Self.clientKey(id)] = etag
        clientsHeld[id] = nil
    }

    // MARK: Hosts

    public func save(_ host: HostRecord) async throws {
        var record = host
        record.owner = record.owner ?? settingsHeld?.record.owner
        let condition: StoreCondition
        if let held = hostsHeld[record.id] {
            guard held.record.withoutRevision != record.withoutRevision else { return }
            record.rev = held.record.rev + 1
            condition = .matching(held.etag)
        } else {
            record.rev = 1
            condition = .absent
        }
        let (kept, etag) = try await write(record, to: Self.hostKey(record.id), when: condition)
        hostsHeld[record.id] = Held(record: kept, etag: etag)
    }

    /// `hosts/remove`: a tombstone. Returns whether there was such a host.
    @discardableResult
    public func remove(_ id: HostID) async throws -> Bool {
        if hostsHeld[id] == nil { try await load() }
        guard let held = hostsHeld[id] else { return false }
        var tombstone = held.record
        tombstone.forgotten = true
        tombstone.rev += 1
        let etag = try await store.put(Self.hostKey(id), try Self.encoder.encode(tombstone), when: .matching(held.etag))
        tombstones[Self.hostKey(id)] = etag
        hostsHeld[id] = nil
        return true
    }

    /// Writes a record, and returns it as the store now has it: dates to the millisecond,
    /// as every other copy will read it, so two copies compare equal.
    private func write<Record: Codable>(_ record: Record, to key: String,
                                        when condition: StoreCondition) async throws -> (Record, String) {
        let data = try Self.encoder.encode(record)
        let etag = try await store.put(key, data, when: condition)
        return (try Self.decoder.decode(Record.self, from: data), etag)
    }

    // MARK: Rules

    static func requireOperator(in clients: [ClientRecord]) throws {
        guard clients.contains(where: { $0.grant == .operator }) else {
            throw JSONRPCError(code: DaemonAPI.Failure.lastOperator,
                               message: "That would leave no client that can change grants. Make another client an operator first.")
        }
    }

    /// A daemon's `devices.json`, read as device clients (the move, R11). The file is left
    /// as it is.
    public static func legacyDevices(at file: URL) -> [ClientRecord] {
        guard let data = try? Data(contentsOf: file),
              let devices = try? decoder.decode([Device].self, from: data) else { return [] }
        return devices.map(ClientRecord.init(device:))
    }

    // MARK: Coding

    /// Dates as the daemon's stores write them: ISO 8601 with fractional seconds.
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(text) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO 8601 date: \(text)")
        }
        return d
    }()
}

private extension HostRecord {
    /// The record as it would compare if nothing but its revision differed.
    var withoutRevision: HostRecord {
        var copy = self
        copy.rev = 0
        return copy
    }
}
