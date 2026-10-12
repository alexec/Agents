import AgentsKitCore
import Foundation

/// Each provider's secrets (#691, research R3): `provider-secrets.json` in the control plane's
/// own home, readable by its user only. Never in the store, which may be a bucket; never on
/// the wire; never in the log. Values go only to the provider's own server, as its
/// environment or its headers.
public actor ProviderSecrets {
    public static let fileName = "provider-secrets.json"

    private let file: URL
    private var held: [String: [String: String]]?

    public init(home: URL) {
        file = home.appendingPathComponent(Self.fileName)
    }

    /// A provider's secrets, by name.
    public func values(_ provider: ProviderID) -> [String: String] {
        load()[provider.rawValue] ?? [:]
    }

    /// Lays `secrets` over what the provider had; an empty value takes one away.
    public func set(_ provider: ProviderID, _ secrets: [String: String]) throws {
        var all = load()
        var mine = all[provider.rawValue] ?? [:]
        for (name, value) in secrets { mine[name] = value.isEmpty ? nil : value }
        all[provider.rawValue] = mine.isEmpty ? nil : mine
        try write(all)
    }

    public func remove(_ provider: ProviderID) throws {
        var all = load()
        guard all.removeValue(forKey: provider.rawValue) != nil else { return }
        try write(all)
    }

    private func load() -> [String: [String: String]] {
        if let held { return held }
        let read = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: [String: String]].self, from: $0) }
        held = read ?? [:]
        return held!
    }

    /// Made 0600 before anything is in it, then moved over the old one.
    private func write(_ all: [String: [String: String]]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(all)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let scratch = file.deletingLastPathComponent().appendingPathComponent(".\(Self.fileName).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: scratch.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ControlService.Failure("the provider secrets could not be written")
        }
        do {
            let handle = try FileHandle(forWritingTo: scratch)
            try handle.write(contentsOf: data)
            try handle.close()
            if FileManager.default.fileExists(atPath: file.path) {
                _ = try FileManager.default.replaceItemAt(file, withItemAt: scratch)
            } else {
                try FileManager.default.moveItem(at: scratch, to: file)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            throw error
        }
        held = all
    }
}
