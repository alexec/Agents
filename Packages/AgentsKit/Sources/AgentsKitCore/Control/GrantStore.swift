import Foundation

/// The control plane's records on disk: `clients.json`, `hosts.json` and `control.json`
/// under the control root, each read whole and written whole, atomically (FR-005).
///
/// The control plane is the only writer. A missing or unreadable file is no clients or
/// no hosts, which is the safe reading: nobody connects with a key that is not on record.
public struct GrantStore: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var clientsFile: URL { root.appendingPathComponent("clients.json") }
    public var hostsFile: URL { root.appendingPathComponent("hosts.json") }
    public var settingsFile: URL { root.appendingPathComponent("control.json") }

    // MARK: Clients

    public func loadClients() -> [ClientRecord] {
        guard let data = try? Data(contentsOf: clientsFile),
              let clients = try? Self.decoder.decode([ClientRecord].self, from: data) else { return [] }
        var seen: Set<UUID> = []
        return clients.filter { seen.insert($0.id).inserted }
    }

    public func saveClients(_ clients: [ClientRecord]) throws {
        try write(clients.sorted { $0.paired < $1.paired }, to: clientsFile)
    }

    /// A daemon's `devices.json`, read as device clients (R7). The file is left as it is.
    public static func legacyDevices(at file: URL) -> [ClientRecord] {
        guard let data = try? Data(contentsOf: file),
              let devices = try? decoder.decode([Device].self, from: data) else { return [] }
        return devices.map(ClientRecord.init(device:))
    }

    // MARK: Hosts

    public func loadHosts() -> [HostRecord] {
        guard let data = try? Data(contentsOf: hostsFile),
              let hosts = try? Self.decoder.decode([HostRecord].self, from: data) else { return [] }
        var seen: Set<HostID> = []
        return hosts.filter { seen.insert($0.id).inserted }
    }

    public func saveHosts(_ hosts: [HostRecord]) throws {
        try write(hosts, to: hostsFile)
    }

    // MARK: Settings

    public func loadSettings() -> ControlSettings? {
        guard let data = try? Data(contentsOf: settingsFile) else { return nil }
        return try? Self.decoder.decode(ControlSettings.self, from: data)
    }

    public func saveSettings(_ settings: ControlSettings) throws {
        try write(settings, to: settingsFile)
    }

    // MARK: Rules

    /// `clients/setGrant`: refuses to leave nobody who may change it back (FR-009).
    public static func settingGrant(_ grant: Grant, of client: UUID,
                                    in clients: [ClientRecord]) throws -> [ClientRecord] {
        guard let index = clients.firstIndex(where: { $0.id == client }) else {
            throw JSONRPCError(code: DaemonAPI.Failure.notAllowed, message: "No client has that id.")
        }
        var changed = clients
        changed[index].grant = grant
        try requireOperator(in: changed)
        return changed
    }

    /// `clients/forget`: the same refusal, for the last operator.
    public static func forgetting(_ client: UUID, in clients: [ClientRecord]) throws -> [ClientRecord] {
        let changed = clients.filter { $0.id != client }
        guard changed.count != clients.count else { return clients }
        try requireOperator(in: changed)
        return changed
    }

    private static func requireOperator(in clients: [ClientRecord]) throws {
        guard clients.contains(where: { $0.grant == .operator }) else {
            throw JSONRPCError(code: DaemonAPI.Failure.lastOperator,
                               message: "That would leave no client that can change grants. Make another client an operator first.")
        }
    }

    // MARK: Coding

    private func write(_ value: some Encodable, to file: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.encoder.encode(value).write(to: file, options: .atomic)
    }

    /// Dates as the daemon's stores write them: ISO 8601 with fractional seconds, read
    /// with or without them.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return e
    }()

    static let decoder: JSONDecoder = {
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
