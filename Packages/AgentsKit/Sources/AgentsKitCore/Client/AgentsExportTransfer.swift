import Foundation

/// Export… and Import… of an agent or a project (#1001), as the window and the Remote do
/// them. The host makes the export; this reads it in parts into a file, and sends a file in
/// parts for an import, so neither is held in memory whole.
public enum AgentsExportTransfer {
    /// A part of an import: what one `agents/importUpload` carries.
    public static let partSize = 1 << 20

    /// Asks the host to make the export `request` names. Read it with `read` before an
    /// hour goes by, or the host removes it.
    public static func make(_ request: DaemonAPI.AgentsExportRequest,
                            on client: DaemonClient) async throws -> DaemonAPI.AgentsExport {
        try await client.call(DaemonAPI.Method.agentsExport, request, returning: DaemonAPI.AgentsExport.self)
    }

    /// Reads the export the host made into `file`, in parts, and the host then removes it.
    public static func read(_ made: DaemonAPI.AgentsExport, from client: DaemonClient, into file: URL) async throws {
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let out = try FileHandle(forWritingTo: file)
        defer { try? out.close() }
        var offset = 0
        while true {
            let part = try await client.call(DaemonAPI.Method.agentsExportRead,
                                             DaemonAPI.SendReadRequest(id: made.file.id, offset: offset),
                                             returning: DaemonAPI.SendRead.self)
            try out.write(contentsOf: part.data)
            offset += part.data.count
            if part.end || part.data.isEmpty { break }
        }
    }

    /// Sends `file` in parts and imports it, into the project at `folder` when one is given.
    public static func importFile(_ file: URL, into client: DaemonClient,
                                  folder: URL? = nil) async throws -> DaemonAPI.BackupRestoreResult {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let upload = UUID()
        var offset = 0
        while let data = try input.read(upToCount: partSize), !data.isEmpty {
            try await client.call(DaemonAPI.Method.agentsImportUpload,
                                  DaemonAPI.ReceiveUploadRequest(upload: upload, offset: offset, data: data))
            offset += data.count
        }
        return try await client.call(DaemonAPI.Method.agentsImport, DaemonAPI.AgentsImportRequest(upload: upload, folder: folder),
                                     returning: DaemonAPI.BackupRestoreResult.self)
    }

    /// What an import did, in a line: "Imported 2 agents into Web, archived." and what it
    /// skipped. `project` is the project they went into, when the person chose one.
    public static func imported(_ result: DaemonAPI.BackupRestoreResult, into project: String? = nil) -> String {
        let into = project.map { " into \($0)" } ?? ""
        let count = (result.restored == 1 ? "1 agent" : "\(result.restored) agents") + into
        let words = "Imported \(count), archived."
        guard result.skipped > 0 else { return result.restored == 0 ? "There were no agents to import." : words }
        let skipped = result.skipped == 1 ? "1 was skipped" : "\(result.skipped) were skipped"
        let lead = result.restored == 0 ? "Imported no agents" : "Imported \(count), archived"
        return "\(lead). \(skipped): already here, or deleted here."
    }
}
