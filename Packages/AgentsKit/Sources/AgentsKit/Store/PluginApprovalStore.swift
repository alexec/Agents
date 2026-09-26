import Foundation

/// The approved digest of each project plugin, by its folder's path, and when approval
/// began — before which nothing waits, so the plugins already in use keep working.
struct PluginApprovals: Codable, Equatable, Sendable {
    var approvalsBegan: Date?
    var approved: [String: String] = [:]
}

struct PluginApprovalStore: Sendable {
    let file: URL

    func load() -> PluginApprovals {
        guard let data = try? Data(contentsOf: file),
              let records = try? StoreCoding.decoder.decode(PluginApprovals.self, from: data) else {
            return PluginApprovals()
        }
        return records
    }

    func save(_ records: PluginApprovals) {
        guard let data = try? StoreCoding.encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
