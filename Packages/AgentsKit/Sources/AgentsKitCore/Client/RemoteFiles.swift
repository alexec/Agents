import Foundation
import Observation

/// A client's end of `files/*` (034): an agent's folder as its daemon reads it. The
/// phone's for the Mac's agents, and the Mac's for a server's (037).
///
/// Nothing here reads a disk. Every listing and every file is asked of the Mac, inside
/// the folders the agent was given, and the answer is what is shown; the phone keeps
/// no copy past the screen that asked for it.
///
/// Watches belong to the connection, so a new connection has none. What is being
/// watched is remembered here and asked for again every time the Mac comes back: only
/// what a pane on screen still shows, because each pane lets its folder go when it goes
/// (#175).
@MainActor
@Observable
public final class RemoteFiles {
    private let client: DaemonClient
    /// How long a read is waited on before it is given up as not answered (#62). A reply
    /// lost between host, control plane and window would otherwise be waited on for good.
    private let patience: Duration

    /// The Mac answered a `files/*` request with "no such method": it predates the panes.
    /// The phone falls back to what it could do before, and says the Mac needs updating
    /// (FR-029). Cleared when a new connection is made, in case the Mac was updated.
    public private(set) var macLacksPanes = false

    /// Counted up for each folder named by `files/changed`, per agent. A pane observes
    /// the count for the folder it shows, or the file's parent, and reads again when it
    /// moves.
    public private(set) var changes: [String: Int] = [:]
    /// Everything changed for an agent, whatever the folder: for pictures, which may sit
    /// anywhere beside the page.
    public private(set) var anyChange: [UUID: Int] = [:]

    /// Counted up each time the Mac is back after being gone. A page with a draft the
    /// Mac never received reads its file again and saves it (034 FR-009).
    public private(set) var reconnections = 0

    /// Each folder watched, with how many panes on screen show it.
    private var watched: [DaemonAPI.FilesWatchRequest: Int] = [:]

    /// The folders watched now, for a test.
    public var watching: Set<DaemonAPI.FilesWatchRequest> { Set(watched.keys) }

    public init(client: DaemonClient, patience: Duration = .seconds(10)) {
        self.client = client
        self.patience = patience
    }

    // MARK: Reading

    public func list(agentID: UUID, folder: URL) async throws -> DirectoryListing {
        let client = client
        return try await asking {
            try await Self.answered(within: patience) {
                try await client.call(DaemonAPI.Method.filesList,
                                      DaemonAPI.FilesListRequest(agentID: agentID, folder: folder.path),
                                      returning: DirectoryListing.self)
            }
        }
    }

    public func read(agentID: UUID, path: String, known: FileStamp? = nil) async throws -> FileReading {
        let client = client
        return try await asking {
            try await Self.answered(within: patience) {
                try await client.call(DaemonAPI.Method.filesRead,
                                      DaemonAPI.FilesReadRequest(agentID: agentID, path: path, knownStamp: known),
                                      returning: FileReading.self)
            }
        }
    }

    // MARK: Watching

    /// Hear about changes under this folder, for one pane. Asked of the Mac once however
    /// many panes show it; each pane that calls this calls `unwatch` when it goes.
    public func watch(agentID: UUID, folder: URL) async {
        let request = DaemonAPI.FilesWatchRequest(agentID: agentID, folder: folder.path)
        watched[request, default: 0] += 1
        guard watched[request] == 1 else { return }
        await askToWatch(request)
    }

    /// The pane showing this folder has gone. The last one to go stops the Mac watching
    /// it, and what was counted for it is let go.
    public func unwatch(agentID: UUID, folder: URL) async {
        let request = DaemonAPI.FilesWatchRequest(agentID: agentID, folder: folder.path)
        guard let count = watched[request] else { return }
        guard count == 1 else {
            watched[request] = count - 1
            return
        }
        watched[request] = nil
        changes[Self.key(request.agentID, request.folder)] = nil
        if !watched.keys.contains(where: { $0.agentID == agentID }) { anyChange[agentID] = nil }
        let client = client
        _ = try? await Self.answered(within: patience) { try await client.call(DaemonAPI.Method.filesUnwatch, request) }
    }

    /// A new connection: it watches nothing yet, and may be to a newer Mac. Only what a
    /// pane still shows is asked for again.
    public func reconnected() async {
        macLacksPanes = false
        reconnections += 1
        for request in watched.keys { await askToWatch(request) }
        // Everything shown may have changed while nobody was listening.
        for agentID in Set(watched.keys.map(\.agentID)) { anyChange[agentID, default: 0] += 1 }
        for request in watched.keys { changes[Self.key(request.agentID, request.folder), default: 0] += 1 }
    }

    /// `files/changed`, from the notification switch.
    public func apply(_ change: DaemonAPI.FilesChangedNotification) {
        anyChange[change.agentID, default: 0] += 1
        // Too many to name (#216): every folder shown for the agent reads again.
        if change.many == true {
            for request in watched.keys where request.agentID == change.agentID {
                changes[Self.key(request.agentID, request.folder), default: 0] += 1
            }
        }
        for folder in change.folders {
            changes[Self.key(change.agentID, Self.standard(folder)), default: 0] += 1
        }
    }

    /// How often this folder has changed. Read in a view to be redrawn when it does.
    public func changeCount(agentID: UUID, folder: URL) -> Int {
        changes[Self.key(agentID, Self.standard(folder.path))] ?? 0
    }

    private func askToWatch(_ request: DaemonAPI.FilesWatchRequest) async {
        let client = client
        _ = try? await asking {
            try await Self.answered(within: patience) { try await client.call(DaemonAPI.Method.filesWatch, request) }
        }
    }

    // MARK: Words

    /// What to say when a read failed, in the Mac's words where it gave some.
    public static func describe(_ error: any Error, name: String) -> String {
        if let error = error as? JSONRPCError {
            if error.code == DaemonAPI.Failure.fileGone { return "\(name) is gone." }
            return error.message
        }
        if error is NoAnswer { return "\(name) took too long to read." }
        return "\(name) could not be read. Your Mac may not be answering."
    }

    /// A read the host did not answer in time.
    public struct NoAnswer: Error, Sendable {}

    public static func isNoAnswer(_ error: any Error) -> Bool { error is NoAnswer }

    /// `work`'s answer, or `NoAnswer` once `patience` is up, whichever comes first.
    ///
    /// Not a task group: a call waiting on a reply does not hear cancellation, and a group
    /// waits for every child before it returns, so it would wait for the lost reply too.
    /// The call left behind ends when its connection does.
    private static func answered<T: Sendable>(within patience: Duration,
                                              _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let settled = ManagedAtomicFlag()
        return try await withCheckedThrowingContinuation { continuation in
            let timer = Task {
                try? await Task.sleep(for: patience)
                if settled.set() { continuation.resume(throwing: NoAnswer()) }
            }
            Task {
                let result: Result<T, any Error>
                do { result = .success(try await work()) } catch { result = .failure(error) }
                if settled.set() {
                    timer.cancel()
                    continuation.resume(with: result)
                }
            }
        }
    }

    public static func isGone(_ error: any Error) -> Bool {
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
