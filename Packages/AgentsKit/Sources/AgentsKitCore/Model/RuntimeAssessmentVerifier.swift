import Foundation

/// Scores a runtime assessment (#47) from the daemon's own record, never the agent's word.
///
/// What it reads: the calls the daemon answered for the agent (`app-tools.jsonl`), the
/// transcript the daemon wrote (endings, questions, the prompts that started it again),
/// the event log, the helpers' records, the leases still held, and whether the report
/// is on disk. The report's own table is not read for a verdict; only that it exists,
/// names the steps, and carries the text answer the person gave.
public enum RuntimeAssessmentVerifier {
    public struct Record: Sendable {
        public var agentID: UUID
        public var runtimeID: String
        public var model: String?
        /// The runtime's own question tool, or nil where it has none the app can carry.
        public var escalationTool: String?
        public var calls: [AppToolCall]
        public var transcript: [TranscriptEntry]
        public var events: [Event]
        /// Every agent this one started, archived or not.
        public var helpers: [Agent]
        /// Names of the resources the agent still holds.
        public var leasesHeld: [String]
        public var reportPath: String?
        public var reportText: String?

        public init(agentID: UUID, runtimeID: String, model: String? = nil, escalationTool: String?,
                    calls: [AppToolCall], transcript: [TranscriptEntry], events: [Event],
                    helpers: [Agent], leasesHeld: [String], reportPath: String?, reportText: String?) {
            self.agentID = agentID
            self.runtimeID = runtimeID
            self.model = model
            self.escalationTool = escalationTool
            self.calls = calls
            self.transcript = transcript
            self.events = events
            self.helpers = helpers
            self.leasesHeld = leasesHeld
            self.reportPath = reportPath
            self.reportText = reportText
        }
    }

    public static func score(_ record: Record, at: Date = Date()) -> RuntimeAssessmentScore {
        let scorer = Scorer(record)
        let checks = RuntimeAssessment.steps.map { step -> RuntimeAssessmentScore.Check in
            let (verdict, evidence) = scorer.check(step.id)
            return .init(id: step.id, area: step.area, verdict: verdict, evidence: evidence)
        }
        return RuntimeAssessmentScore(agentID: record.agentID, runtimeID: record.runtimeID,
                                      model: record.model, scoredAt: at,
                                      reportPath: record.reportPath, checks: checks)
    }

    /// The report path an agent showed, if it showed a Markdown file under
    /// `.agents/reviews/runtimes/`.
    public static func shownReport(in calls: [AppToolCall]) -> String? {
        calls.filter { $0.method == DaemonAPI.Method.agentsShowFile && $0.ok }
            .compactMap { $0.arguments?["file"]?["path"]?.stringValue }
            .first { $0.contains(".agents/reviews/runtimes/") && $0.hasSuffix(".md") }
    }
}

private struct Scorer {
    typealias Verdict = RuntimeAssessmentScore.Verdict
    let record: RuntimeAssessmentVerifier.Record

    init(_ record: RuntimeAssessmentVerifier.Record) { self.record = record }

    func check(_ id: String) -> (Verdict, String) {
        switch id {
        case "show_file": showFile()
        case "leases": leases()
        case "workflows": workflows()
        case "dashboard": dashboard()
        case "events": events()
        case "ask_form": askForm()
        case "own_ask": ownAsk()
        case "helpers": helpers()
        case "wait": wait()
        case "ending": ending()
        case "report": report()
        default: (.failed, "no check for this step")
        }
    }

    // MARK: Reading the record

    func calls(_ method: String) -> [AppToolCall] { record.calls.filter { $0.method == method } }

    /// "answered" or the refusal, for the evidence column.
    func said(_ calls: [AppToolCall], _ tool: String) -> String {
        guard let last = calls.last else { return "`\(tool)` never called" }
        if last.ok { return "`\(tool)` answered" }
        return "`\(tool)` refused: \(String((last.answer ?? "").prefix(160)))"
    }

    func ok(_ calls: [AppToolCall]) -> Bool { calls.contains(where: \.ok) }

    /// Prompts the app sent the agent itself: a cleared block, a check-again, a wait's end.
    var appPrompts: [(at: Date, text: String)] {
        record.transcript.compactMap { entry in
            if case .userMessage(let text, _, _) = entry.kind { return (entry.at, text) }
            return nil
        }
    }

    // MARK: The steps

    func showFile() -> (Verdict, String) {
        let shown = calls(DaemonAPI.Method.agentsShowFile)
        guard let path = RuntimeAssessmentVerifier.shownReport(in: shown) else {
            return (.failed, shown.isEmpty ? "`show_file` never called"
                    : "`show_file` never opened a report under .agents/reviews/runtimes/ (\(said(shown, "show_file")))")
        }
        let first = shown.first { $0.ok && $0.arguments?["file"]?["path"]?.stringValue == path }
        let beforeIt = first?.answer?.contains("open, empty") == true
        guard beforeIt else { return (.failed, "`show_file` opened \(name(path)) only after it was written") }
        guard record.reportText != nil else { return (.failed, "\(name(path)) was shown but is not on disk") }
        return (.passed, "`show_file` opened \(name(path)) empty, before the first write")
    }

    func leases() -> (Verdict, String) {
        let leased = calls(DaemonAPI.Method.leasesLease).filter(\.ok)
        guard let name = leased.first?.arguments?["name"]?.stringValue else {
            return (.failed, said(calls(DaemonAPI.Method.leasesLease), "lease_resource"))
        }
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard ok(calls(DaemonAPI.Method.leasesList)) else { return (.failed, said(calls(DaemonAPI.Method.leasesList), "list_resources")) }
        let released = calls(DaemonAPI.Method.leasesRelease).filter {
            $0.ok && $0.arguments?["name"]?.stringValue?.trimmingCharacters(in: .whitespaces).lowercased() == key
        }
        guard !released.isEmpty else { return (.failed, said(calls(DaemonAPI.Method.leasesRelease), "release_resource")) }
        // Granted names the agent; released names only the resource, so it is the release
        // of that resource after this agent's grant.
        let onIt = record.events.filter { $0.details["resource"]?.lowercased() == key }
        guard let granted = onIt.first(where: { $0.name == "lease.granted" && $0.details["agent"] == record.agentID.uuidString }) else {
            return (.failed, "no lease.granted to this agent for \(name) on the log")
        }
        guard onIt.contains(where: { $0.name == "lease.released" && $0.position > granted.position }) else {
            return (.failed, "no lease.released for \(name) on the log")
        }
        guard !record.leasesHeld.contains(where: { $0.lowercased() == key }) else { return (.failed, "\(name) is still held") }
        return (.passed, "\(name): granted, listed, released; nothing left held")
    }

    func workflows() -> (Verdict, String) {
        let listed = calls(DaemonAPI.Method.agentsManageWorkflows).filter { $0.arguments?["action"]?.stringValue == "list" }
        guard ok(listed) else { return (.failed, said(listed.isEmpty ? calls(DaemonAPI.Method.agentsManageWorkflows) : listed, "manage_workflows list")) }
        let changed = calls(DaemonAPI.Method.agentsManageWorkflows).contains { $0.ok && $0.arguments?["action"]?.stringValue != "list" && $0.arguments?["action"]?.stringValue != "read" }
        return (.passed, "`manage_workflows` listed them" + (changed ? " (and changed one, which it was told not to)" : ""))
    }

    func dashboard() -> (Verdict, String) {
        for (method, tool) in [(DaemonAPI.Method.dashboardSetTile, "set_tile"),
                               (DaemonAPI.Method.dashboardRead, "read_dashboard"),
                               (DaemonAPI.Method.dashboardRemoveTile, "remove_tile")] {
            guard ok(calls(method)) else { return (.failed, said(calls(method), tool)) }
        }
        return (.passed, "`set_tile`, `read_dashboard` and `remove_tile` answered")
    }

    func events() -> (Verdict, String) {
        let ping = RuntimeAssessment.pingEvent
        let published = calls(DaemonAPI.Method.eventsPublish).filter { $0.arguments?["name"]?.stringValue == ping }
        guard ok(published) else { return (.failed, said(published, "publish_event \(ping)")) }
        guard record.events.contains(where: { $0.name == ping && $0.publisher?.agentID == record.agentID }) else {
            return (.failed, "\(ping) is not on the log from this agent")
        }
        let waited = calls(DaemonAPI.Method.eventsWait).filter {
            $0.ok && ($0.arguments?["events"]?.arrayValue ?? []).contains { $0.stringValue == ping }
        }
        guard let heard = waited.first(where: { $0.answer?.contains(ping) == true && !($0.answer ?? "").lowercased().contains("still waiting") }) else {
            return (.failed, waited.isEmpty ? "never waited for \(ping)" : "the wait for \(ping) did not come back with it")
        }
        let seconds = heard.seconds.map { String(format: " in %.1f s", $0) } ?? ""
        return (.passed, "published \(ping); the wait came back with it\(seconds)")
    }

    /// The form's questions, from the call's arguments.
    func questions(_ call: AppToolCall) -> [(id: String, prompt: String, choices: Bool)] {
        (call.arguments?["questions"]?.arrayValue ?? []).compactMap { q in
            guard let id = q["id"]?.stringValue, let prompt = q["prompt"]?.stringValue else { return nil }
            return (id, prompt, !(q["options"]?.arrayValue ?? []).isEmpty)
        }
    }

    func answered(after: Date) -> [ElicitationAnswer] {
        record.transcript.filter { $0.at >= after }.compactMap { entry -> [ElicitationAnswer]? in
            if case .elicitationAnswered(_, _, let answers) = entry.kind, !answers.isEmpty { return answers }
            return nil
        }.first ?? []
    }

    func askForm() -> (Verdict, String) {
        let asked = calls(DaemonAPI.Method.agentsAskForm)
        guard let call = asked.first(where: \.ok) else { return (.failed, said(asked, "ask_form")) }
        let qs = questions(call)
        guard qs.contains(where: \.choices), let text = qs.first(where: { !$0.choices }) else {
            return (.failed, "`ask_form` was not asked with both a choice and a text field")
        }
        let answers = answered(after: call.at)
        guard let given = answers.first(where: { $0.question == text.prompt })?.answer, !given.isEmpty else {
            return (.failed, "no answer to \"\(text.prompt)\" in the record")
        }
        guard call.answer?.contains(given) == true else {
            return (.failed, "the person typed \"\(given)\" and `ask_form` did not hand it back")
        }
        guard record.reportText?.contains(given) == true else {
            return (.failed, "\"\(given)\" came back to the agent but is not in its report")
        }
        return (.passed, "answered; \"\(given)\" came back unchanged and is in the report")
    }

    func ownAsk() -> (Verdict, String) {
        let viaForm = calls(DaemonAPI.Method.agentsAskForm).count
        let asked = record.transcript.filter { if case .elicitationAsked = $0.kind { return true } else { return false } }
        let own = asked.count - viaForm
        if own > 0 {
            return (.passed, "\(own) question\(own == 1 ? "" : "s") reached the app through \(record.escalationTool.map { "`\($0)`" } ?? "the runtime's own tool")")
        }
        guard let tool = record.escalationTool else {
            return (.notOffered, "the runtime has no question tool the app can carry")
        }
        return (.failed, "nothing asked with `\(tool)` reached the app")
    }

    func helpers() -> (Verdict, String) {
        let started = calls(DaemonAPI.Method.agentsStartHelper)
        guard let call = started.first(where: { $0.ok && $0.agentID != nil }), let id = call.agentID else {
            return (.failed, said(started, "start_agent"))
        }
        guard let helper = record.helpers.first(where: { $0.id == id }) else {
            return (.failed, "the helper \(id.uuidString.prefix(8)) is not marked as this agent's")
        }
        guard ok(calls(DaemonAPI.Method.agentsListHelpers)) else { return (.failed, said(calls(DaemonAPI.Method.agentsListHelpers), "list_my_agents")) }
        // Resumed when it finished, or told at the block that it already had (a quick
        // runtime's helper can end before its starter's turn does).
        let resumed = appPrompts.contains { $0.at > call.at && $0.text.contains("The block you reported has cleared") }
        guard resumed || blockFoundHelperDone(id) else {
            return (.failed, "never started again when the helper finished")
        }
        let parked = calls(DaemonAPI.Method.agentsParkHelper).filter { $0.arguments?["agentID"]?.stringValue?.uppercased() == id.uuidString }
        guard ok(parked) else { return (.failed, said(parked, "park_agent")) }
        guard record.events.contains(where: { $0.name == "agent.parked" && $0.details["agent"] == id.uuidString }) else {
            return (.failed, "no agent.parked for the helper on the log")
        }
        let archived = calls(DaemonAPI.Method.agentsArchiveHelper).filter { $0.arguments?["agentID"]?.stringValue?.uppercased() == id.uuidString }
        guard ok(archived) else { return (.failed, said(archived, "archive_agent")) }
        guard helper.archivedAt != nil, helper.archivedReason == .byAgent else {
            return (.failed, "the helper is not archived by an agent")
        }
        return (.passed, "helper \(id.uuidString.prefix(8)) on \(helper.runtimeID): marked as this agent's, resumed this one when it finished, parked, archived")
    }

    /// A block on the helper refused because the helper had already ended: the daemon's
    /// own account of the helper finishing first.
    func blockFoundHelperDone(_ helper: UUID?) -> Bool {
        calls(DaemonAPI.Method.agentsFinishTurn).contains { call in
            !call.ok && call.arguments?["outcome"]?.stringValue == "blocked"
                && (call.answer ?? "").contains("has already ended")
                && (helper == nil || (call.arguments?["waitingOn"]?.arrayValue ?? [])
                    .contains { $0.stringValue?.uppercased() == helper?.uuidString })
        }
    }

    func wait() -> (Verdict, String) {
        let never = RuntimeAssessment.neverEvent
        let waits = calls(DaemonAPI.Method.eventsWait).filter {
            ($0.arguments?["events"]?.arrayValue ?? []).contains { $0.stringValue == never }
        }
        guard let call = waits.first(where: { $0.ok && $0.arguments?["untilMinutes"]?.intValue != nil }) else {
            return (.failed, waits.isEmpty ? "never waited for \(never)" : "waited for \(never) without until_minutes, or was refused")
        }
        if call.answer?.contains("timed out") == true { return (.passed, "the call itself came back timed out") }
        guard appPrompts.contains(where: { $0.at > call.at && $0.text.contains("timed out") }) else {
            return (.failed, "the wait never timed out back into the conversation")
        }
        return (.passed, "waited \(call.arguments?["untilMinutes"]?.intValue ?? 0) min for \(never); started again when it timed out")
    }

    func ending() -> (Verdict, String) {
        let finished = calls(DaemonAPI.Method.agentsFinishTurn).filter(\.ok)
        let blocked = finished.filter { $0.arguments?["outcome"]?.stringValue == "blocked" }
        let onHelper = blocked.contains { !($0.arguments?["waitingOn"]?.arrayValue ?? []).isEmpty }
            || blockFoundHelperDone(nil)
        let withTime = blocked.contains { $0.arguments?["checkAgainInMinutes"]?.intValue != nil }
        let last = finished.last?.arguments?["outcome"]?.stringValue
        // A block refused only because the helper had already ended still carried what it said.
        let sent = finished + calls(DaemonAPI.Method.agentsFinishTurn).filter {
            !$0.ok && ($0.answer ?? "").contains("has already ended")
        }
        let titled = sent.contains { !($0.arguments?["title"]?.stringValue ?? "").isEmpty }
        let prompted = sent.contains { !($0.arguments?["prompts"]?.arrayValue ?? []).isEmpty }
        let outcomes = finished.compactMap { $0.arguments?["outcome"]?.stringValue }.joined(separator: ", ")
        var missing: [String] = []
        if !onHelper { missing.append("blocked on the helper") }
        if !withTime { missing.append("blocked with a check-again time") }
        if last != "done" && last != "needs_answer" { missing.append("a last done or needs_answer") }
        if !titled { missing.append("a title") }
        if !prompted { missing.append("a next prompt") }
        let silent = silentEndings()
        if silent > 0 { missing.append("\(silent) turn\(silent == 1 ? "" : "s") ended without an account") }
        let refused = calls(DaemonAPI.Method.agentsFinishTurn).filter { !$0.ok }.count
        let note = refused > 0 ? " (\(refused) refused first)" : ""
        guard missing.isEmpty else {
            return (.failed, "recorded: \(outcomes.isEmpty ? "nothing" : outcomes)\(note); missing: " + missing.joined(separator: ", "))
        }
        return (.passed, "recorded: \(outcomes)\(note); every turn ended with an account")
    }

    /// Turns that ended (`finished`) with no report recorded since they began.
    func silentEndings() -> Int {
        var reported = true
        var silent = 0
        for entry in record.transcript {
            switch entry.kind {
            case .stateChanged(.running, _), .stateChanged(.starting, _):
                reported = false
            case .workReported:
                reported = true
            case .stateChanged(.finished, _):
                if !reported { silent += 1 }
                reported = true
            default:
                break
            }
        }
        return silent
    }

    func report() -> (Verdict, String) {
        guard let path = record.reportPath else { return (.failed, "no report was shown, so none was found") }
        guard let text = record.reportText else { return (.failed, "\(name(path)) is not on disk") }
        let missing = RuntimeAssessment.steps.map(\.id).filter { !text.contains($0) }
        guard missing.isEmpty else { return (.failed, "\(name(path)) leaves out " + missing.joined(separator: ", ")) }
        return (.passed, "\(name(path)) names every step")
    }

    func name(_ path: String) -> String { (path as NSString).lastPathComponent }
}
