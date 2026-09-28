import Foundation
import AgentsKitCore

struct GitHubProjectAssignmentEntry: Codable, Hashable, Sendable {
    var folder: URL
    var repository: GitHubRepository
    var assignment: GitHubIssueAssignment
}

struct GitHubProjectRecords: Codable, Sendable {
    var boards: [GitHubProjectBoard] = []
    var assignments: [GitHubProjectAssignmentEntry] = []
    var lastAttemptAt: [String: Date] = [:]

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        boards = (try c.decodeIfPresent([Lossy<GitHubProjectBoard>].self, forKey: .boards) ?? [])
            .compactMap(\.value)
        assignments = (try c.decodeIfPresent([Lossy<GitHubProjectAssignmentEntry>].self, forKey: .assignments) ?? [])
            .compactMap(\.value)
        lastAttemptAt = try c.decodeIfPresent([String: Date].self, forKey: .lastAttemptAt) ?? [:]
    }

    func board(folder: URL) -> GitHubProjectBoard? {
        let folder = Project.standardize(folder)
        return boards.first { $0.folder == folder }
    }

    mutating func setBoard(_ board: GitHubProjectBoard?, folder: URL) {
        let folder = Project.standardize(folder)
        boards.removeAll { $0.folder == folder }
        if let board { boards.append(board) }
    }

    func assignment(folder: URL, projectID: String, itemID: String) -> GitHubProjectAssignmentEntry? {
        let folder = Project.standardize(folder)
        return assignments.first {
            $0.folder == folder && $0.assignment.projectID == projectID && $0.assignment.itemID == itemID
        }
    }

    func assignment(requestID: UUID) -> GitHubProjectAssignmentEntry? {
        assignments.first { $0.assignment.requestID == requestID }
    }

    mutating func setAssignment(_ entry: GitHubProjectAssignmentEntry) {
        assignments.removeAll {
            $0.folder == entry.folder
                && $0.assignment.projectID == entry.assignment.projectID
                && $0.assignment.itemID == entry.assignment.itemID
        }
        assignments.append(entry)
    }

    mutating func updateAssignment(folder: URL, projectID: String, itemID: String,
                                   _ update: (inout GitHubProjectAssignmentEntry) -> Void) {
        let folder = Project.standardize(folder)
        guard let index = assignments.firstIndex(where: {
            $0.folder == folder && $0.assignment.projectID == projectID && $0.assignment.itemID == itemID
        }) else { return }
        update(&assignments[index])
    }
}

/// The daemon's cache and local issue-to-agent links. Nothing in this file is written to a
/// repository, and losing the board cache costs a refresh rather than an agent's work.
public struct GitHubProjectStore: Sendable {
    private let locations: StoreLocations

    public init(locations: StoreLocations) { self.locations = locations }

    func load() -> GitHubProjectRecords {
        guard let data = try? Data(contentsOf: locations.githubProjects),
              let records = try? StoreCoding.decoder.decode(GitHubProjectRecords.self, from: data) else {
            return GitHubProjectRecords()
        }
        return records
    }

    func save(_ records: GitHubProjectRecords) {
        guard let data = try? StoreCoding.encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        try? data.write(to: locations.githubProjects, options: .atomic)
    }
}
