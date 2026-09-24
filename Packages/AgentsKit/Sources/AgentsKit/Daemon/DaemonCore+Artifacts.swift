import Foundation

/// The person's half of a live page: what they typed, put on disk by the daemon.
///
/// The daemon writes rather than the window for one reason — so that it knows the
/// person did. An agent's writes reach the page through the folder watch, and so do
/// the person's; the file cannot tell the two apart, and the agent, on its next turn,
/// needs to be told which passages are no longer the ones it wrote (022 FR-016). The
/// moment of the write is the one moment that fact is known for certain, and this is
/// where it is recorded.
///
/// Nothing here is persisted. The edit itself is on disk in the file, where the agent
/// can read it; what is held is only the note that it happened, and a daemon that
/// restarts forgets the note by design (data-model.md).
extension DaemonCore {
    /// One passage the person changed, for the note to the agent.
    struct ArtifactEdit: Hashable, Sendable {
        var path: String
        /// The passage's lines in the document as written, counted from one.
        var lines: ClosedRange<Int>
        /// The passage as written.
        var text: String
        var at: Date
    }

    /// The most edits held per agent before the oldest are dropped. Past this the
    /// note says "and more; read the file" rather than growing without limit.
    static let artifactEditLimit = 20

    /// Write what the person typed on a page, inside the agent's folders and nowhere
    /// else, and remember which passages changed.
    public func artifactWrite(_ request: DaemonAPI.ArtifactWriteRequest) async throws {
        guard let agent = agents[request.agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        guard request.path.hasPrefix("/") else {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "The path has to be absolute, starting at `/`.")
        }
        let scope = agent.folderScope
        guard scope.allows(request.path) else {
            // The same sentence a refused read or a refused show gets: one rule, said
            // one way, whichever door it is met at.
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: scope.refusal(for: request.path))
        }
        let url = URL(filePath: request.path)
        let previous = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard previous != request.text else { return }
        do {
            try Data(request.text.utf8).write(to: url, options: .atomic)
        } catch {
            throw JSONRPCError(code: JSONRPCError.internalError,
                               message: "Could not save \(url.lastPathComponent): \(error.localizedDescription)")
        }
        rememberArtifactEdits(agentID: request.agentID, path: request.path,
                              previous: previous, written: request.text)
    }

    /// Which passages the person changed, coalesced by place: a passage edited twice
    /// before the agent's next turn is one note holding the later text.
    func rememberArtifactEdits(agentID: UUID, path: String, previous: String, written: String) {
        let change = PassageChange.between(old: previous, new: written)
        let passages = Passage.split(written)
        var edits = artifactEdits[agentID] ?? []
        for index in change.changed where passages.indices.contains(index) {
            let passage = passages[index]
            let edit = ArtifactEdit(path: path, lines: passage.lines, text: passage.source, at: now())
            edits.removeAll { $0.path == path && $0.lines == passage.lines }
            edits.append(edit)
        }
        if edits.count > Self.artifactEditLimit {
            edits.removeFirst(edits.count - Self.artifactEditLimit)
        }
        artifactEdits[agentID] = edits
    }
}
