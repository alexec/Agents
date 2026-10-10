import AgentsKitCore
import Foundation

/// What the app last approved of each guarded file in each project, and the change
/// waiting on the person (#502).
struct GuardedFileState: Codable, Equatable, Sendable {
    var folder: URL
    var path: String
    /// SHA-256 of the approved file; nil when the approved state is no file.
    var approvedDigest: String?
    /// The approved file itself, so the app goes on using it while a change waits and
    /// Undo can write it back without git.
    var approvedContent: Data?
    var pending: Pending?

    /// A change seen and not yet decided.
    struct Pending: Codable, Equatable, Sendable {
        var digest: String?
        var since: Date
        var changedByIDs: [UUID] = []
        /// Their titles when it was seen, so a session deleted later is still named.
        var changedBy: [String] = []
        var byGit = false
    }

    var file: GuardedFile? { GuardedFile(rawValue: path) }
}

struct GuardedFileRecords: Codable, Equatable, Sendable {
    var approvalsBegan: Date?
    var states: [GuardedFileState] = []
    /// Read from a file that is there and could not be read: nothing is approved, and a
    /// change made with no turn running waits too. Not written.
    var unreadable = false

    enum CodingKeys: String, CodingKey { case approvalsBegan, states }

    func state(_ folder: URL, _ file: GuardedFile) -> GuardedFileState? {
        states.first { $0.folder == folder && $0.path == file.path }
    }

    mutating func update(_ folder: URL, _ file: GuardedFile, _ change: (inout GuardedFileState) -> Void) {
        if let index = states.firstIndex(where: { $0.folder == folder && $0.path == file.path }) {
            change(&states[index])
        } else {
            var state = GuardedFileState(folder: folder, path: file.path)
            change(&state)
            states.append(state)
        }
    }
}

struct GuardedFileStore: Sendable {
    let file: URL

    /// A file that cannot be read approves nothing, and is left as it is (`ApprovalFile`).
    func load() -> GuardedFileRecords {
        switch ApprovalFile.read(GuardedFileRecords.self, at: file, began: \.approvalsBegan) {
        case .missing: return GuardedFileRecords()
        case .read(let records): return records
        case .unreadable: return GuardedFileRecords(approvalsBegan: Date(), unreadable: true)
        }
    }

    /// `replacing` is the person's own act, the only write that replaces a file that
    /// could not be read.
    func save(_ records: GuardedFileRecords, replacing: Bool = false) throws {
        var records = records
        if records.approvalsBegan == nil { records.approvalsBegan = Date() }
        let data = try StoreCoding.encoder.encode(records)
        try ApprovalFile.write(data, to: file, overUnreadable: records.unreadable, replacing: replacing,
                               began: true)
    }
}
