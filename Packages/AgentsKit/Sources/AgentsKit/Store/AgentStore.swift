import Foundation

/// The record on disk. The daemon is its only writer, and the app never reads the
/// directory: it asks the daemon. One reader of the truth, and no file locking between
/// processes to get wrong.
public actor AgentStore {
    public let locations: StoreLocations
    private var appendHandles: [UUID: FileHandle] = [:]

    public init(locations: StoreLocations = .default) throws {
        self.locations = locations
        try locations.createDirectories()
    }

    // MARK: Records

    /// Written whole and atomically on every change, because a half-written record is
    /// an agent we can no longer account for.
    public func save(_ agent: Agent) throws {
        try FileManager.default.createDirectory(at: locations.agent(agent.id), withIntermediateDirectories: true)
        let data = try StoreCoding.encoder.encode(agent)
        try data.write(to: locations.record(agent.id), options: .atomic)
    }

    public func load(_ id: UUID) throws -> Agent {
        let data = try Data(contentsOf: locations.record(id))
        return try StoreCoding.decoder.decode(Agent.self, from: data)
    }

    /// Every agent there has ever been, newest activity first.
    ///
    /// A record that will not decode is skipped rather than thrown, so one bad file
    /// cannot stop the daemon starting and losing sight of everything else.
    public func loadAll() -> (agents: [Agent], unreadable: [URL]) {
        var agents: [Agent] = []
        var unreadable: [URL] = []
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: locations.agents, includingPropertiesForKeys: nil)) ?? []
        for directory in contents {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            do {
                agents.append(try load(id))
            } catch {
                unreadable.append(locations.record(id))
            }
        }
        agents.sort { $0.lastActivityAt > $1.lastActivityAt }
        return (agents, unreadable)
    }

    // MARK: Transcripts

    /// Appended, never rewritten. The handle is kept open because this is called for
    /// every chunk a runtime emits.
    public func append(_ entry: TranscriptEntry, for agentID: UUID) throws {
        let handle = try appendHandle(for: agentID)
        var line = try StoreCoding.encoder.encode(entry)
        line.append(0x0A)
        try handle.write(contentsOf: line)
    }

    public func appendAll(_ entries: [TranscriptEntry], for agentID: UUID) throws {
        for entry in entries { try append(entry, for: agentID) }
    }

    private func appendHandle(for agentID: UUID) throws -> FileHandle {
        if let handle = appendHandles[agentID] { return handle }
        let url = locations.transcript(agentID)
        try FileManager.default.createDirectory(at: locations.agent(agentID), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        appendHandles[agentID] = handle
        return handle
    }

    /// Let go of an agent's handle: it is finished, or archived, or the daemon is going.
    public func closeTranscript(for agentID: UUID) {
        try? appendHandles.removeValue(forKey: agentID)?.close()
    }

    public func closeAll() {
        for (_, handle) in appendHandles { try? handle.close() }
        appendHandles.removeAll()
    }

    /// A page of a transcript, newest last. Never the whole thing.
    public func transcript(for agentID: UUID, before: Int? = nil, limit: Int = 200) throws -> TranscriptPage {
        try TranscriptReader(url: locations.transcript(agentID)).page(before: before, limit: limit)
    }

    public func transcriptCount(for agentID: UUID) throws -> Int {
        try TranscriptReader(url: locations.transcript(agentID)).count
    }
}

public struct TranscriptPage: Codable, Hashable, Sendable {
    /// The index of the first entry in `entries` within the whole transcript, so the
    /// app can ask for the page before this one.
    public var firstIndex: Int
    public var total: Int
    public var entries: [TranscriptEntry]

    public init(firstIndex: Int, total: Int, entries: [TranscriptEntry]) {
        self.firstIndex = firstIndex
        self.total = total
        self.entries = entries
    }

    public var hasMoreBefore: Bool { firstIndex > 0 }
}
