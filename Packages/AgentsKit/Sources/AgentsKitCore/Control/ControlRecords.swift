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
    /// Keys listed in the store whose object could not be decoded, by entity tag (#171).
    /// Such a member is not known *and* not forgotten: it is refused as `unavailable`,
    /// and nobody is closed over it. A record held from before keeps being used.
    private var unreadable: [String: String] = [:]
    /// Says a key could not be read, once per version of it.
    private var onUnreadable: (@Sendable (String) -> Void)?

    public init(store: any ControlStore) { self.store = store }

    /// Where an unreadable record is said, once per version (the service's log).
    public func onUnreadable(_ say: @escaping @Sendable (String) -> Void) { onUnreadable = say }

    // MARK: Reading

    /// Everything, from the store. At start-up, and as the backstop every 15 s (R4): only
    /// objects whose tag changed are read again.
    public func load() async throws {
        var clients: [UUID: Held<ClientRecord>] = [:]
        var listed: Set<String> = []
        for entry in try await store.list(prefix: Self.clientsPrefix) {
            listed.insert(entry.key)
            if let held = clientsHeld.values.first(where: { Self.clientKey($0.record.id) == entry.key && $0.etag == entry.etag }) {
                clients[held.record.id] = held
                continue
            }
            if tombstones[entry.key] == entry.etag { continue }
            guard let object = try await store.get(entry.key) else { continue }
            guard let record = try? Self.decoder.decode(ClientRecord.self, from: object.data) else {
                noteUnreadable(entry.key, etag: object.etag)
                if let held = clientsHeld.values.first(where: { Self.clientKey($0.record.id) == entry.key }) {
                    clients[held.record.id] = held
                }
                continue
            }
            unreadable[entry.key] = nil
            if record.forgotten == true { tombstones[entry.key] = object.etag; continue }
            clients[record.id] = Held(record: record, etag: object.etag)
        }
        var hosts: [HostID: Held<HostRecord>] = [:]
        for entry in try await store.list(prefix: Self.hostsPrefix) {
            listed.insert(entry.key)
            if let held = hostsHeld.values.first(where: { Self.hostKey($0.record.id) == entry.key && $0.etag == entry.etag }) {
                hosts[held.record.id] = held
                continue
            }
            if tombstones[entry.key] == entry.etag { continue }
            guard let object = try await store.get(entry.key) else { continue }
            guard let record = try? Self.decoder.decode(HostRecord.self, from: object.data) else {
                noteUnreadable(entry.key, etag: object.etag)
                if let held = hostsHeld.values.first(where: { Self.hostKey($0.record.id) == entry.key }) {
                    hosts[held.record.id] = held
                }
                continue
            }
            unreadable[entry.key] = nil
            if record.forgotten == true { tombstones[entry.key] = object.etag; continue }
            hosts[record.id] = Held(record: record, etag: object.etag)
        }
        // A key no longer listed is no longer unreadable.
        unreadable = unreadable.filter { listed.contains($0.key) || $0.key == Self.settingsKey }
        clientsHeld = clients
        hostsHeld = hosts
        if let object = try await store.get(Self.settingsKey) {
            if let settings = try? Self.decoder.decode(ControlSettings.self, from: object.data) {
                settingsHeld = Held(record: settings, etag: object.etag)
                unreadable[Self.settingsKey] = nil
            } else {
                noteUnreadable(Self.settingsKey, etag: object.etag)
            }
        }
    }

    private func noteUnreadable(_ key: String, etag: String) {
        guard unreadable[key] != etag else { return }
        unreadable[key] = etag
        onUnreadable?("store: \(key) could not be read; it is left as it is, and its member is refused as unavailable rather than forgotten")
    }

    /// Listed, and its record could not be read: neither known nor forgotten (#171).
    public func isUnreadable(_ id: UUID) -> Bool { unreadable[Self.clientKey(id)] != nil }
    public func isUnreadable(_ id: HostID) -> Bool { unreadable[Self.hostKey(id)] != nil }

    public var clients: [ClientRecord] { clientsHeld.values.map(\.record).sorted { $0.paired < $1.paired } }
    public var hosts: [HostRecord] { hostsHeld.values.map(\.record).sorted { $0.id.rawValue < $1.id.rawValue } }
    public func client(_ id: UUID) -> ClientRecord? { clientsHeld[id]?.record }
    /// Forgotten, and its tombstone still kept (seven days): refused as `forgotten`, not `unknown`.
    public func wasForgotten(_ id: UUID) -> Bool { tombstones[Self.clientKey(id)] != nil }
    public func host(_ id: HostID) -> HostRecord? { hostsHeld[id]?.record }
    public var settings: ControlSettings? { settingsHeld?.record }

    // MARK: Settings

    /// The settings, made once if there are none. Two copies starting on an empty store
    /// both try; the one that loses reads the winner's.
    ///
    /// Settings that are there and cannot be read are never made afresh over: they hold
    /// the owner and the key every member was paired against. Start-up stops and says so
    /// (#171), where it used to try to make them, lose to the file it could not read, and
    /// try again for ever.
    public func settings(orMake make: @Sendable () -> ControlSettings) async throws -> ControlSettings {
        try await settings(orMake: make, attempt: 1)
    }

    private func settings(orMake make: @Sendable () -> ControlSettings, attempt: Int) async throws -> ControlSettings {
        if let settings = settingsHeld?.record { return settings }
        if let object = try await store.get(Self.settingsKey) {
            do {
                let settings = try Self.decoder.decode(ControlSettings.self, from: object.data)
                settingsHeld = Held(record: settings, etag: object.etag)
                return settings
            } catch {
                throw StoreError.unavailable("\(Self.settingsKey) can't be read (\(error)); it is left as it is. "
                    + "Restore it from a backup, or move it aside to start a new control plane and pair everything again")
            }
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
        } catch StoreError.conflict where attempt < 3 {
            settingsHeld = nil
            return try await settings(orMake: make, attempt: attempt + 1)
        }
    }

    /// Changes the settings against the version read. Another copy on the same bucket may
    /// have written them since (it writes its own address when it starts, T128): the change
    /// is made again on what is there now, a few times at most.
    public func changeSettings(_ change: (inout ControlSettings) -> Void) async throws -> ControlSettings {
        for attempt in 1...3 {
            guard let held = settingsHeld else { throw StoreError.unavailable("there are no settings to change yet") }
            var settings = held.record
            change(&settings)
            guard settings != held.record else { return settings }
            settings.rev = (settings.rev ?? 0) + 1
            do {
                let (kept, etag) = try await write(settings, to: Self.settingsKey, when: .matching(held.etag))
                settingsHeld = Held(record: kept, etag: etag)
                return kept
            } catch StoreError.conflict where attempt < 3 {
                guard let object = try await store.get(Self.settingsKey),
                      let now = try? Self.decoder.decode(ControlSettings.self, from: object.data) else { throw StoreError.conflict(key: Self.settingsKey) }
                settingsHeld = Held(record: now, etag: object.etag)
            }
        }
        throw StoreError.conflict(key: Self.settingsKey)
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
            condition = Self.overTombstone(tombstones[key])
        }
        let (kept, etag) = try await write(record, to: key, when: condition)
        clientsHeld[record.id] = Held(record: kept, etag: etag)
        tombstones[key] = nil
    }

    /// `clients/forget`: a tombstone against the version read. Nothing happens for a
    /// client that is not known. The last client may go too (#111): Agents Host, on the
    /// control plane's own Mac, can always make a code for another.
    public func forget(_ id: UUID) async throws {
        if clientsHeld[id] == nil { try await load() }
        guard let held = clientsHeld[id] else { return }
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
            condition = Self.overTombstone(tombstones[Self.hostKey(record.id)])
        }
        let (kept, etag) = try await write(record, to: Self.hostKey(record.id), when: condition)
        hostsHeld[record.id] = Held(record: kept, etag: etag)
        tombstones[Self.hostKey(record.id)] = nil
    }

    /// Where a record is new: an empty key, or the tombstone left when the same id was
    /// forgotten. A Remote keeps its id, so a device forgotten and paired again is written
    /// over its tombstone (2026-10-01: an absent-only write conflicted for ever, after the
    /// code was spent).
    private static func overTombstone(_ etag: String?) -> StoreCondition {
        etag.map { .matching($0) } ?? .absent
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
