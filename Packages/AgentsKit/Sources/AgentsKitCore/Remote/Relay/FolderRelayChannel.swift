// Not on Linux: the server build of agentsd has no relay (037, 046).
#if canImport(CryptoKit)
import Foundation

/// iCloud as a folder (058, T096): what a walk runs `agents-relay` and a fake device
/// against when they are two processes, so neither touches the person's iCloud.
///
/// One folder per device's zone, one file per frame, named as the frame is so a retried
/// post replaces what it wrote. Each end keeps its own idea of what it has read, as a
/// `FakeRelayChannel` does. `AGENTS_RELAY_FOLDER` chooses it.
public actor FolderRelayChannel: RelayChannel {
    public let folder: URL
    private var seen: [UUID: Set<String>] = [:]
    private var listed: [UUID: Set<String>] = [:]

    public init(folder: URL) {
        self.folder = folder
    }

    private func zone(_ device: UUID) -> URL { folder.appendingPathComponent(device.uuidString, isDirectory: true) }

    private static func file(_ name: String) -> String { name.replacingOccurrences(of: "/", with: "_") + ".json" }

    private struct Stored: Codable {
        var session: UUID
        var toMac: Bool
        var seq: Int64
        var sealed: Data
        var sentAt: Date
    }

    public func ensureZone(device: UUID) async throws {
        try FileManager.default.createDirectory(at: zone(device), withIntermediateDirectories: true)
    }

    public func post(_ record: FrameRecord, device: UUID) async throws {
        guard FileManager.default.fileExists(atPath: zone(device).path) else { throw RelayChannelError.zoneGone }
        let stored = Stored(session: record.session, toMac: record.direction == .toMac, seq: record.seq,
                            sealed: record.sealed, sentAt: record.sentAt)
        try JSONEncoder().encode(stored).write(to: zone(device).appendingPathComponent(Self.file(record.name)),
                                               options: .atomic)
    }

    private func names(_ device: UUID) throws -> [String] {
        guard FileManager.default.fileExists(atPath: zone(device).path) else { throw RelayChannelError.zoneGone }
        return try FileManager.default.contentsOfDirectory(atPath: zone(device).path).filter { $0.hasSuffix(".json") }
    }

    public func fetchChanges(device: UUID) async throws -> [FrameRecord] {
        var read = seen[device] ?? []
        var out: [FrameRecord] = []
        for name in try names(device) where !read.contains(name) {
            guard let data = try? Data(contentsOf: zone(device).appendingPathComponent(name)),
                  let stored = try? JSONDecoder().decode(Stored.self, from: data) else { continue }
            read.insert(name)
            out.append(FrameRecord(session: stored.session, direction: stored.toMac ? .toMac : .toDevice,
                                   seq: stored.seq, sealed: stored.sealed, sentAt: stored.sentAt))
        }
        seen[device] = read
        return out.sorted { $0.sentAt < $1.sentAt }
    }

    public func changedDevices() async throws -> [UUID] {
        let devices = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.compactMap(UUID.init(uuidString:)) ?? []
        var changed: [UUID] = []
        for device in devices {
            let now = Set((try? names(device)) ?? [])
            if !now.subtracting(listed[device] ?? []).isEmpty { changed.append(device) }
            listed[device] = now
        }
        return changed
    }

    public func delete(_ names: [String], device: UUID) async throws {
        for name in names { try? FileManager.default.removeItem(at: zone(device).appendingPathComponent(Self.file(name))) }
    }

    public func deleteZone(device: UUID) async throws {
        try? FileManager.default.removeItem(at: zone(device))
    }

    public func sweep(olderThan date: Date) async throws {
        let devices = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.compactMap(UUID.init(uuidString:)) ?? []
        for device in devices {
            for name in (try? names(device)) ?? [] {
                let file = zone(device).appendingPathComponent(name)
                guard let data = try? Data(contentsOf: file), let stored = try? JSONDecoder().decode(Stored.self, from: data),
                      stored.sentAt < date else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

/// The notices mailbox as a folder, beside `FolderRelayChannel`: one file per need per
/// device, a later item replacing the earlier, as CloudKit's record does.
public struct FolderMailbox: Mailbox {
    public let folder: URL
    public init(folder: URL) { self.folder = folder }

    public func post(_ item: MailboxItem) async throws {
        let place = folder.appendingPathComponent("mailbox", isDirectory: true)
            .appendingPathComponent(item.device.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(item).write(to: place.appendingPathComponent(item.needID.token.replacingOccurrences(of: ":", with: "_") + ".json"), options: .atomic)
    }

    /// What one device finds waiting, for a walk to read back.
    public func waiting(for device: UUID) -> [MailboxItem] {
        let place = folder.appendingPathComponent("mailbox", isDirectory: true)
            .appendingPathComponent(device.uuidString, isDirectory: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let names = (try? FileManager.default.contentsOfDirectory(atPath: place.path)) ?? []
        return names.compactMap { name in
            (try? Data(contentsOf: place.appendingPathComponent(name))).flatMap { try? decoder.decode(MailboxItem.self, from: $0) }
        }.sorted { $0.postedAt < $1.postedAt }
    }
}
#endif
