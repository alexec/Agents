import AgentsKitCore
import Foundation
import Observation

/// The phone's end of `files/*` (034): an agent's folder as the Mac's daemon reads it.
///
/// Nothing here reads a disk. Every listing and every file is asked of the Mac, inside
/// the folders the agent was given, and the answer is what is shown; the phone keeps
/// no copy past the screen that asked for it.
///
/// Watches belong to the connection, so a new connection has none. What was being
/// watched is remembered here and asked for again every time the Mac comes back.
@MainActor
@Observable
final class RemoteFiles {
    private let client: DaemonClient

    /// The Mac answered a `files/*` request with "no such method": it predates the panes.
    /// The phone falls back to what it could do before, and says the Mac needs updating
    /// (FR-029). Cleared when a new connection is made, in case the Mac was updated.
    private(set) var macLacksPanes = false

    /// Counted up for each folder named by `files/changed`, per agent. A pane observes
    /// the count for the folder it shows, or the file's parent, and reads again when it
    /// moves.
    private(set) var changes: [String: Int] = [:]
    /// Everything changed for an agent, whatever the folder: for pictures, which may sit
    /// anywhere beside the page.
    private(set) var anyChange: [UUID: Int] = [:]

    private var watched: Set<DaemonAPI.FilesWatchRequest> = []

    init(client: DaemonClient) {
        self.client = client
    }

    // MARK: Reading

    func list(agentID: UUID, folder: URL) async throws -> DirectoryListing {
        try await asking {
            try await client.call(DaemonAPI.Method.filesList,
                                  DaemonAPI.FilesListRequest(agentID: agentID, folder: folder.path),
                                  returning: DirectoryListing.self)
        }
    }

    func read(agentID: UUID, path: String, known: FileStamp? = nil) async throws -> FileReading {
        try await asking {
            try await client.call(DaemonAPI.Method.filesRead,
                                  DaemonAPI.FilesReadRequest(agentID: agentID, path: path, knownStamp: known),
                                  returning: FileReading.self)
        }
    }

    // MARK: Watching

    /// Hear about changes under this folder. Idempotent here and on the Mac.
    func watch(agentID: UUID, folder: URL) async {
        let request = DaemonAPI.FilesWatchRequest(agentID: agentID, folder: folder.path)
        guard watched.insert(request).inserted else { return }
        _ = try? await asking { try await client.call(DaemonAPI.Method.filesWatch, request) }
    }

    func unwatch(agentID: UUID, folder: URL) async {
        let request = DaemonAPI.FilesWatchRequest(agentID: agentID, folder: folder.path)
        guard watched.remove(request) != nil else { return }
        _ = try? await client.call(DaemonAPI.Method.filesUnwatch, request)
    }

    /// A new connection: it watches nothing yet, and may be to a newer Mac.
    func reconnected() async {
        macLacksPanes = false
        for request in watched {
            _ = try? await asking { try await client.call(DaemonAPI.Method.filesWatch, request) }
        }
        // Everything shown may have changed while nobody was listening.
        for agentID in Set(watched.map(\.agentID)) { anyChange[agentID, default: 0] += 1 }
        for request in watched { changes[Self.key(request.agentID, request.folder), default: 0] += 1 }
    }

    /// `files/changed`, from the notification switch.
    func apply(_ change: DaemonAPI.FilesChangedNotification) {
        anyChange[change.agentID, default: 0] += 1
        for folder in change.folders {
            changes[Self.key(change.agentID, Self.standard(folder)), default: 0] += 1
        }
    }

    /// How often this folder has changed. Read in a view to be redrawn when it does.
    func changeCount(agentID: UUID, folder: URL) -> Int {
        changes[Self.key(agentID, Self.standard(folder.path))] ?? 0
    }

    // MARK: Words

    /// What to say when a read failed, in the Mac's words where it gave some.
    static func describe(_ error: any Error, name: String) -> String {
        if let error = error as? JSONRPCError {
            if error.code == DaemonAPI.Failure.fileGone { return "\(name) is gone." }
            return error.message
        }
        return "\(name) could not be read. Your Mac may not be answering."
    }

    static func isGone(_ error: any Error) -> Bool {
        (error as? JSONRPCError)?.code == DaemonAPI.Failure.fileGone
    }

    private func asking<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as JSONRPCError where error.isMethodNotFound {
            macLacksPanes = true
            throw error
        }
    }

    private static func key(_ agentID: UUID, _ folder: String) -> String {
        "\(agentID.uuidString)|\(standard(folder))"
    }

    private static func standard(_ path: String) -> String {
        URL(filePath: path).standardizedFileURL.path
    }
}
