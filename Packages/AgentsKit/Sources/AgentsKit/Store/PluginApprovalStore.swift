import Foundation

/// The approved digest of each project plugin, by its folder's path, and when approval
/// began — before which nothing waits, so the plugins already in use keep working.
struct PluginApprovals: Codable, Equatable, Sendable {
    var approvalsBegan: Date?
    var approved: [String: String] = [:]
    /// Read from a file that is there and could not be read (#169): approval has begun
    /// and nothing is approved. Not written.
    var unreadable = false

    enum CodingKeys: String, CodingKey { case approvalsBegan, approved }
}

struct PluginApprovalStore: Sendable {
    let file: URL

    /// A file that cannot be read approves nothing, and is left as it is (`ApprovalFile`).
    func load() -> PluginApprovals {
        switch ApprovalFile.read(PluginApprovals.self, at: file, began: \.approvalsBegan) {
        case .missing: return PluginApprovals()
        case .read(let records): return records
        case .unreadable: return PluginApprovals(approvalsBegan: Date(), unreadable: true)
        }
    }

    /// `replacing` is the person's own act, the only write that replaces a file that
    /// could not be read.
    func save(_ records: PluginApprovals, replacing: Bool = false) throws {
        let data = try StoreCoding.encoder.encode(records)
        try ApprovalFile.write(data, to: file, overUnreadable: records.unreadable, replacing: replacing,
                               began: records.approvalsBegan != nil)
    }
}
