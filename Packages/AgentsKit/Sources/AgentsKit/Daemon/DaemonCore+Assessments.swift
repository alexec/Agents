import Foundation
import AgentsKitCore

/// Assessing a runtime (#47): starting the agent that does the steps, keeping the record
/// it is scored from, and scoring it.
///
/// The record is the daemon's own. Every call an agent makes to the app's tools is kept,
/// as the daemon answered it, in `app-tools.jsonl` beside its transcript; the transcript,
/// the event log, the helpers' records and the lease book are the rest. The agent's
/// report is read only for whether it is there and names the steps.
extension DaemonCore {
    // MARK: Starting one

    public func assessRuntime(_ request: DaemonAPI.AssessRuntimeRequest) async throws -> DaemonAPI.AssessRuntimeResult {
        guard let runtime = RuntimeCatalog.runtime(id: request.runtimeID) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "There is no runtime called \(request.runtimeID).")
        }
        let folder = request.folder.standardizedFileURL
        // What the runtime offers here, from a draft of the session the agent then starts
        // on: the cheapest of its models, whether or not it has been used here before.
        let draft = try await options(DaemonAPI.OptionsRequest(runtimeID: runtime.id, cwd: folder))
        let model = RuntimeAssessment.cheapestModel(in: draft.options)
        let today = now()
        let report = RuntimeAssessment.freshReportPath(project: folder, runtimeID: runtime.id, date: today)
        // show_file takes a Markdown file that is not there yet only in a folder that is.
        try? FileManager.default.createDirectory(at: report.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let day = RuntimeAssessment.reportPath(project: folder, runtimeID: runtime.id, date: today)
            .deletingPathExtension().lastPathComponent.dropFirst(runtime.id.count + 1)
        let shortID = String(UUID().uuidString.prefix(8)).lowercased()
        let scope = RuntimeAssessment.scopePath(root: locations.root, shortID: shortID)
        let version = await runtimeVersion(draft: draft.draftID)
        let host = Self.assessmentHost
        let brief = RuntimeAssessment.brief(
            runtimeID: runtime.id, runtimeName: runtime.name, model: model, runtimeVersion: version,
            host: host, reportPath: report.path, scopePath: scope.path,
            escalationTool: ToolPolicyCatalog.policy(for: runtime.id).escalationTool,
            agentShortID: shortID, date: String(day))
        let options = model.map { StartOptions(values: ["model": .string($0)]) } ?? .none
        let start = DaemonAPI.StartRequest(runtimeID: runtime.id, cwd: folder, prompt: brief,
                                           startOptions: options, draftID: draft.draftID,
                                           labels: [RuntimeAssessment.label])
        let id = try await self.start(start, startedBy: nil, labelOwner: .agent)
        let kept = RuntimeAssessment.Start(agentID: id, runtimeID: runtime.id, runtimeVersion: version,
                                           host: host, reportPath: report.path, scopePath: scope.path,
                                           shortID: shortID)
        keepQuietly("a runtime assessment's start") {
            try FileManager.default.createDirectory(at: locations.assessments, withIntermediateDirectories: true)
            try StoreCoding.encoder.encode(kept).write(to: startURL(id), options: .atomic)
        }
        return .init(agentID: id, model: model, reportPath: report.path)
    }

    /// The adapter's name and version from the draft's handshake, such as
    /// "@agentclientprotocol/claude-agent-acp 0.81.2"; nil when it gave neither.
    private func runtimeVersion(draft: UUID) async -> String? {
        guard let pending = drafts[draft]?.pending,
              let info = await (try? pending.value.session)?.initializeResult?.agentInfo else { return nil }
        let words = [info.name ?? info.title, info.version].compactMap { $0 }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// Where an assessment runs: this daemon's machine.
    static var assessmentHost: String {
        #if os(macOS)
        "this Mac (\(ProcessInfo.processInfo.hostName))"
        #else
        "the server \(ProcessInfo.processInfo.hostName)"
        #endif
    }

    func startURL(_ agentID: UUID) -> URL {
        locations.assessments.appendingPathComponent("\(agentID.uuidString).start.json")
    }

    // MARK: The record

    /// Keep one app tool call, as answered. Called for every call that carries a token
    /// that speaks for an agent; costs a line per call.
    func keepAppToolCall(_ agentID: UUID, method: String, params: JSONValue?,
                         answer: Result<JSONValue, JSONRPCError>, began: Date) {
        let call: AppToolCall
        switch answer {
        case .success(let value):
            call = AppToolCall(at: began, method: method, ok: true,
                               arguments: AppToolCall.keptArguments(params),
                               answer: value["note"]?.stringValue,
                               agentID: value["agentID"]?.stringValue.flatMap(UUID.init(uuidString:)),
                               seconds: now().timeIntervalSince(began))
        case .failure(let error):
            call = AppToolCall(at: began, method: method, ok: false,
                               arguments: AppToolCall.keptArguments(params), answer: error.message,
                               seconds: now().timeIntervalSince(began))
        }
        keepQuietly("a record of an app tool call") {
            var line = try StoreCoding.encoder.encode(call)
            line.append(0x0A)
            let url = locations.appTools(agentID)
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        }
    }

    func appToolCalls(_ agentID: UUID) -> [AppToolCall] {
        Self.jsonLines(locations.appTools(agentID), as: AppToolCall.self)
    }

    static func jsonLines<T: Decodable>(_ url: URL, as: T.Type) -> [T] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? StoreCoding.decoder.decode(T.self, from: Data($0.utf8)) }
    }

    // MARK: Scoring

    /// After an assessing agent's last turn (not one that ended blocked), score it and
    /// put the table in its conversation.
    func scoreAssessmentIfDue(_ agentID: UUID) {
        guard let agent = agents[agentID], agent.startedByAgent == nil,
              agent.labels.contains(where: { $0.normalizedValue == RuntimeAssessment.label }),
              // Not while it waits, and not on the way into or out of a worktree.
              agent.report?.outcome != .blocked, agent.report?.outcome != .partlyDone else { return }
        Task {
            guard let score = try? await self.assessment(agentID) else { return }
            await self.record(.runtimeNote(score.note), for: agentID)
        }
    }

    /// Score an assessing agent now, from the record, and keep the score.
    public func assessment(_ agentID: UUID) async throws -> RuntimeAssessmentScore {
        guard let agent = agents[agentID] ?? (try? StoreCoding.decoder.decode(
            Agent.self, from: Data(contentsOf: locations.record(agentID)))) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "There is no agent \(agentID).")
        }
        let calls = appToolCalls(agentID)
        let transcript = Self.jsonLines(locations.transcript(agentID), as: TranscriptEntry.self)
        loadEventsIfNeeded()
        let events = eventLog.events.filter { $0.at >= agent.createdAt }
        let helperIDs = Set(calls.compactMap(\.agentID))
            .union(agents.values.filter { $0.startedByAgent == agentID }.map(\.id))
        let helpers = helperIDs.compactMap { id in
            agents[id] ?? (try? StoreCoding.decoder.decode(Agent.self, from: Data(contentsOf: locations.record(id))))
        }
        _ = loadLeasesIfNeeded()
        let held = leaseBook.entries.filter { $0.value.lease(of: agentID) != nil }.map(\.key.key)
        let reportPath = RuntimeAssessmentVerifier.shownReport(in: calls)
        let reportText = reportPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        let start = try? StoreCoding.decoder.decode(RuntimeAssessment.Start.self, from: Data(contentsOf: startURL(agentID)))
        let workflowLeft = start.map {
            FileManager.default.fileExists(atPath: WorkflowFile.folder(in: agent.projectFolder)
                .appendingPathComponent("\(RuntimeAssessment.throwawayWorkflowID($0.shortID)).md").path)
        } ?? false
        let scopeWritten = start.map { FileManager.default.fileExists(atPath: $0.scopePath) } ?? false
        let record = RuntimeAssessmentVerifier.Record(
            agentID: agentID, runtimeID: agent.runtimeID,
            model: agent.startOptions.values["model"]?.stringValue,
            escalationTool: ToolPolicyCatalog.policy(for: agent.runtimeID).escalationTool,
            calls: calls, transcript: transcript, events: events, helpers: helpers,
            leasesHeld: held, reportPath: reportPath, reportText: reportText,
            start: start, title: agent.title, worktreeNow: agent.worktree?.name,
            workflowLeft: workflowLeft, scopeWritten: scopeWritten)
        let score = RuntimeAssessmentVerifier.score(record, at: now())
        keepQuietly("a runtime assessment's score") {
            try FileManager.default.createDirectory(at: locations.assessments, withIntermediateDirectories: true)
            let encoder = StoreCoding.encoder
            try encoder.encode(score).write(
                to: locations.assessments.appendingPathComponent("\(agentID.uuidString).json"), options: .atomic)
        }
        return score
    }
}
