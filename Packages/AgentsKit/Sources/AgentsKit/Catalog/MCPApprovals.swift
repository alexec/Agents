import AgentsKitCore
import Foundation

/// Which project MCP entries the person has approved, by a digest of each entry, and
/// when approval began — before which nothing waits, so servers already in use keep
/// working (060, R6, contracts/mcp-json.md).
///
/// Kept in the daemon's root, outside the project: a file an agent can write must not
/// be able to approve itself. Same idea as `PluginApprovalStore`.
struct MCPApprovals: Codable, Equatable, Sendable {
    var approvalsBegan: Date?
    var approved: [String: String]
    /// Read from a file that is there and could not be read (#169): approval has begun
    /// and nothing is approved. Not written.
    var unreadable = false

    enum CodingKeys: String, CodingKey { case approvalsBegan, approved }

    init(approvalsBegan: Date? = nil, approved: [String: String] = [:], unreadable: Bool = false) {
        self.approvalsBegan = approvalsBegan
        self.approved = approved
        self.unreadable = unreadable
    }

    static let relativeFile = ".agents/mcp.json"

    /// `folder|relative-file|server-name`. The folder is `Project.standardize`'d, so a
    /// symlink and a trailing slash are the same project the rest of the app already agrees on.
    static func key(folder: URL, name: String) -> String {
        "\(Project.standardize(folder).path)|\(relativeFile)|\(name)"
    }

    static func digest(of entry: OrderedJSON) -> String {
        ContentDigest.sha256(Data(entry.canonicalJSON().utf8))
    }

    /// Approved, or waiting on this digest. Nothing waits before approval has begun.
    func status(folder: URL, name: String, entry: OrderedJSON) -> DaemonAPI.MCPApprovalState {
        let digest = Self.digest(of: entry)
        guard approvalsBegan != nil else { return .approved }
        let stored = approved[Self.key(folder: folder, name: name)]
        if stored == digest { return .approved }
        return .waiting(digest: digest, isNew: stored == nil)
    }

    func isApproved(folder: URL, name: String, entry: OrderedJSON) -> Bool {
        if case .approved = status(folder: folder, name: name, entry: entry) { return true }
        return false
    }

    /// The sheet wrote this entry: it is the one approved, from now.
    mutating func recordAdded(folder: URL, name: String, entry: OrderedJSON) {
        approved[Self.key(folder: folder, name: name)] = Self.digest(of: entry)
    }

    /// The person's Approve. The digest must be the entry's now, or nothing is stored.
    mutating func approve(folder: URL, name: String, digest: String, entry: OrderedJSON) throws {
        guard Self.digest(of: entry) == digest else { throw DaemonAPI.MCPCatalogError.staleDigest }
        approved[Self.key(folder: folder, name: name)] = digest
    }

    mutating func drop(folder: URL, name: String) {
        approved.removeValue(forKey: Self.key(folder: folder, name: name))
    }

    /// Entries already in a project when approval begins, approved as they stand.
    mutating func stampExisting(in folder: URL) {
        guard let root = try? MCPJSONFile.loadOrEmpty(at: MCPJSONFile.projectURL(folder: folder)),
              let pairs = root["mcpServers"]?.objectPairs else { return }
        for (name, entry) in pairs {
            approved[Self.key(folder: folder, name: name)] = Self.digest(of: entry)
        }
    }
}

struct MCPApprovalStore: Sendable {
    let file: URL

    /// A file that cannot be read approves nothing, and is left as it is (`ApprovalFile`).
    func load() -> MCPApprovals {
        switch ApprovalFile.read(MCPApprovals.self, at: file, began: \.approvalsBegan) {
        case .missing: return MCPApprovals()
        case .read(let records): return records
        case .unreadable: return MCPApprovals(approvalsBegan: Date(), unreadable: true)
        }
    }

    /// `replacing` is the person's own act, the only write that replaces a file that
    /// could not be read.
    func save(_ records: MCPApprovals, replacing: Bool = false) throws {
        let data = try StoreCoding.encoder.encode(records)
        try ApprovalFile.write(data, to: file, overUnreadable: records.unreadable, replacing: replacing,
                               began: records.approvalsBegan != nil)
    }
}

/// One destination's servers, for the project section and `mcp/list` (060, frame D).
enum MCPProjectListing {
    struct Result: Equatable, Sendable {
        var servers: [DaemonAPI.ProjectMCPServer]
        var problem: String?
    }

    static func list(destination: DaemonAPI.SkillDestination, personalHome: URL?,
                     sidecar: MCPCatalogSidecar, approvals: MCPApprovals) -> Result {
        let url: URL
        let folder: URL?
        switch destination {
        case .personal:
            guard let home = personalHome else { return Result(servers: [], problem: nil) }
            url = MCPJSONFile.personalURL(home: home)
            folder = nil
        case .project(let path):
            let project = URL(filePath: path)
            url = MCPJSONFile.projectURL(folder: project)
            folder = project
        }

        let root: OrderedJSON
        do {
            root = try MCPJSONFile.loadOrEmpty(at: url)
        } catch let problem as MCPJSONFile.Problem {
            return Result(servers: [], problem: problem.message)
        } catch {
            return Result(servers: [], problem: "mcp.json could not be read.")
        }

        let parsed: [MCPServer]
        switch PersonalDotAgents.servers(at: url) {
        case .success(let servers): parsed = servers
        case .failure(let problem):
            return Result(servers: [], problem: problem.message)
        }

        let secrets: SecretsEnv = {
            guard let home = personalHome else { return SecretsEnv(lines: []) }
            return SecretsEnv.load(from: SecretsEnv.url(home: home))
        }()

        var rows: [DaemonAPI.ProjectMCPServer] = []
        for server in parsed {
            guard let entry = root["mcpServers"]?[server.name] else { continue }
            let approval: DaemonAPI.MCPApprovalState
            if let folder {
                approval = approvals.status(folder: folder, name: server.name, entry: entry)
            } else {
                approval = .approved
            }
            let record = sidecar.record(destination: destination, name: server.name)
            let managed: DaemonAPI.ManagedMCPServer? = record.flatMap { record in
                guard let run = DaemonAPI.MCPRunKind(rawValue: record.run) else { return nil }
                return DaemonAPI.ManagedMCPServer(name: server.name, registryName: record.registryName,
                                                  version: record.version, run: run, addedAt: record.addedAt,
                                                  destination: destination)
            }
            var seen = Set<String>()
            let secretNames = SecretsEnv.referencedNames(in: server).filter { seen.insert($0).inserted }
            let missing = secretNames.filter { secrets.value(of: $0) == nil }
            rows.append(DaemonAPI.ProjectMCPServer(
                name: server.name, summary: summary(server), managed: managed, approval: approval,
                missingSecrets: missing, secretNames: secretNames, entryDigest: MCPApprovals.digest(of: entry)))
        }

        let waiting = rows.filter { if case .waiting = $0.approval { true } else { false } }
        let ready = rows.filter { if case .approved = $0.approval { true } else { false } }
        return Result(servers: waiting + ready, problem: nil)
    }

    /// The command line or URL, with `${NAME}` still visible.
    static func summary(_ server: MCPServer) -> String {
        switch server.transport {
        case .stdio(let command, let args, _):
            return ([command] + args).joined(separator: " ")
        case .http(let url, _), .sse(let url, _):
            return url
        }
    }
}
