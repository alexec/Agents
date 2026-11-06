// Not on Linux, as `CloudKitMailbox` is not.
#if canImport(CryptoKit)
import Foundation

/// The notices mailbox as a folder, for a walk: one file per need per device, a later
/// item replacing the earlier, as CloudKit's record does.
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

    /// One device's count, as `count.json` beside its items (#1163).
    public func post(_ count: MailboxCount) async throws {
        let place = folder.appendingPathComponent("mailbox", isDirectory: true)
            .appendingPathComponent(count.device.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(count).write(to: place.appendingPathComponent("count.json"), options: .atomic)
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
