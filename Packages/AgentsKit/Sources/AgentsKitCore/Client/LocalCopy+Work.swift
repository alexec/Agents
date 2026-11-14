import CryptoKit
import Foundation

/// Work's part of the local copy (#4930): the last answers of the Work pages, keyed by ref
/// (#4727) and by what was asked, so a page seen before draws at once and its host's answer
/// replaces it. A cache, never the record: a write (merge, approve, close, label) always acts on
/// the host's own answer.
extension LocalCopy {
    /// What a Work entry holds, each with how many of it are kept, the newest first.
    public enum WorkGroup: String, CaseIterable, Sendable {
        /// The first page of a list (issues, PRs, releases) with its lineage figures.
        case list
        /// An issue or a PR opened: its body and its newest page of comments.
        case item
        /// An epic's plan (`forge/plan`).
        case plan
        /// Work ▸ Features (`work/features`).
        case features
        /// Work ▸ Timeline (`work/timeline`, the Mac's).
        case timeline
        /// Work ▸ Deploys (`deploys/targets`, the Mac's).
        case deploys
        /// The boards (`forge/boards`).
        case boards
        /// A forge's picture (`forge/image`), by URL: it does not change. Kept to its own cap.
        case image

        public var kept: Int {
            switch self {
            case .list: 30
            case .item: 50
            case .plan: 50
            case .features: 10
            case .timeline: 20
            case .deploys: 5
            case .boards: 10
            case .image: 2000
            }
        }
    }

    /// The most the pictures hold: a quarter of the copy's cap.
    public var imageCap: Int { cap / 4 }

    /// A Work entry's ref (#4727): the group, and what was asked.
    public static func workRef(_ group: WorkGroup, _ asked: String) -> WireRef {
        WireRef(provider: "agents", type: "work", topic: group.rawValue, id: asked)
    }

    var work: URL { folder.appendingPathComponent("work", isDirectory: true) }

    private func workFile(_ ref: WireRef, _ group: WorkGroup) -> URL {
        // What was asked can be long (a picture's URL): the file's name is its hash, and the ref is in the file.
        let hash = SHA256.hash(data: Data(ref.description.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return work.appendingPathComponent(group.rawValue, isDirectory: true).appendingPathComponent(hash + ".json")
    }

    /// The last answer kept for what was asked; nil with none, or one of another form.
    public func work<Value: Codable & Sendable>(_: Value.Type, _ group: WorkGroup, _ asked: String) -> Value? {
        workRead(Value.self, group, asked)?.value
    }

    /// The last answer kept for what was asked, with when the client read it from its host
    /// (#5142), for the "Last update" line; nil with none, or one of another form. A file
    /// written before the time was kept gives the file's own time.
    public func workRead<Value: Codable & Sendable>(_: Value.Type, _ group: WorkGroup, _ asked: String) -> (value: Value, at: Date)? {
        let ref = Self.workRef(group, asked)
        let url = workFile(ref, group)
        guard let record = read(Value.self, at: url), record.ref == ref else { return nil }
        let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return (record.value, record.at ?? written ?? .distantPast)
    }

    /// A host's answer, kept, then the copy trimmed to its caps. `at` is when the client read
    /// it from its host; now when not given.
    public func keepWork<Value: Codable & Sendable>(_ value: Value, _ group: WorkGroup, _ asked: String, readAt at: Date = Date()) {
        let ref = Self.workRef(group, asked)
        write(Record(ref: ref, value: value, at: at), to: workFile(ref, group))
        trim()
    }

    /// Each group to its count, the pictures to their cap; what is left, for the copy's own cap.
    func trimWork() -> [(url: URL, at: Date, bytes: Int)] {
        var left: [(url: URL, at: Date, bytes: Int)] = []
        for group in WorkGroup.allCases {
            var held = Self.files(work.appendingPathComponent(group.rawValue, isDirectory: true)).sorted { $0.at > $1.at }
            var total = held.reduce(0) { $0 + $1.bytes }
            while let oldest = held.last, held.count > group.kept || (group == .image && total > imageCap) {
                try? FileManager.default.removeItem(at: oldest.url)
                total -= oldest.bytes
                held.removeLast()
            }
            left += held
        }
        return left
    }
}
