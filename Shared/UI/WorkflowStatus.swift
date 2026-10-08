import AgentsKitCore
import Foundation

/// One line of a workflow page's status card (#142): what is true, and whether it wants
/// a person. Here so the Mac and the Remote say the same lines in the same order; the
/// web page's `workflowStatus.ts` says them too.
struct WorkflowStatusLine: Identifiable {
    var symbol: String
    var text: String
    var detail: String? = nil
    var tint: StateTint = .none
    /// The agent "Open the agent" goes to, on the line that has one.
    var agentID: UUID? = nil
    var id: String { symbol + text }
}

extension WorkflowSummary {
    /// Everything that decides whether it runs, a line each, most important first:
    /// what stops it, then what it is doing, then when it next runs. The heading keeps
    /// only the summary sentence, so none of this is said twice.
    var statusLines: [WorkflowStatusLine] {
        var lines: [WorkflowStatusLine] = []
        if isArchived {
            lines.append(WorkflowStatusLine(symbol: "archivebox",
                                            text: "Archived — it will not run until it is brought back",
                                            detail: "Archived workflows count towards neither limit"))
        }
        if let problem = workflow.problem {
            lines.append(WorkflowStatusLine(symbol: "exclamationmark.triangle", text: problem.message,
                                            detail: problem.needsAPerson ? "The file is below" : "Left alone until this version knows it",
                                            tint: problem.needsAPerson ? .failure : .none))
        }
        lines += mcpArgumentLines
        if waitsItsTurn, let limit = overLimit {
            lines.append(WorkflowStatusLine(symbol: "hourglass", text: "Waiting its turn: \(limit.sentence)",
                                            detail: limit.remedy, tint: .attention))
        } else if let waiting = awaitingApproval {
            lines.append(WorkflowStatusLine(symbol: "checkmark.shield",
                                            text: waiting.note.map { "Waiting for your OK — \($0)" }
                                                ?? (waiting.isNew ? "New — waiting for your OK" : "Changed since you approved it — waiting for your OK"),
                                            detail: "Read the prompt and settings below, then Approve to let it run",
                                            tint: .attention))
        } else if deniedHere != nil {
            lines.append(WorkflowStatusLine(symbol: "hand.raised.slash",
                                            text: "Denied on this host — it does not run here",
                                            detail: "Other hosts still see it waiting. Approve to let it run here"))
        }
        if !isArchived {
            lines.append(enabledLine)
        }
        if let limit = overLimit, !waitsItsTurn {
            lines.append(WorkflowStatusLine(symbol: "exclamationmark.triangle", text: "Over the limit: \(limit.sentence)",
                                            detail: limit.remedy, tint: .attention))
        }
        if isRunning {
            var agentID: UUID?
            if case .ran(let ran, _) = lastOutcome { agentID = ran }
            lines.append(WorkflowStatusLine(symbol: "play.circle", text: "Running now", agentID: agentID))
        }
        if let end = cooldownEndsAt {
            lines.append(WorkflowStatusLine(symbol: "hourglass",
                                            text: "Cooling down until \(end.formatted(date: .omitted, time: .shortened))",
                                            detail: holdsAFire ? "A trigger came in meanwhile; it runs once then" : nil))
        }
        if case .refused = lastOutcome, let outcome = lastOutcome {
            lines.append(WorkflowStatusLine(symbol: "xmark.circle", text: outcome.summary,
                                            tint: needsAPerson && awaitingApproval == nil && overLimit == nil
                                                ? .attention : .none))
        }
        lines.append(nextLine)
        return lines
    }

    /// Whether the switch is on, and where that came from: the file, an agent, or the
    /// person here (#124, #125).
    private var enabledLine: WorkflowStatusLine {
        let file = "\(WorkflowPaths.folderName)/\(workflowID).\(WorkflowPaths.fileExtension)"
        guard !isEnabled else {
            return WorkflowStatusLine(symbol: "checkmark.circle",
                                      text: workflow.enabled == true ? "On — its file says enabled: true"
                                                                     : "On — its file does not say enabled:, so it is on",
                                      detail: "Enabled writes enabled: false into \(file)")
        }
        let text: String
        switch offReason {
        case .file?: text = "Off — its file says enabled: false"
        case .writtenByAgent?: text = "Off — written by an agent, so it arrived off"
        case .agent?: text = "Off — an agent turned it off"
        case .person?, nil: text = "Off — turned off here"
        }
        return WorkflowStatusLine(symbol: "pause.circle", text: text,
                                  detail: "None of its triggers run it; Run now still does. It still counts towards the workflow limits")
    }

    /// When it next runs, or that nothing will until something changes.
    private var nextLine: WorkflowStatusLine {
        let blocked = isArchived || !isEnabled || workflow.problem != nil
            || awaitingApproval != nil || deniedHere != nil || overLimit != nil
        if let next = nextFireAt, !blocked {
            return WorkflowStatusLine(symbol: "calendar",
                                      text: "Next run \(next.formatted(.relative(presentation: .named)))",
                                      detail: next.formatted(date: .abbreviated, time: .shortened))
        }
        if !blocked, workflow.canFire {
            return WorkflowStatusLine(symbol: "bolt", text: "Runs when one of its triggers fires")
        }
        return WorkflowStatusLine(symbol: "calendar", text: "No next run",
                                  detail: blocked ? "Until what is above changes" : "Nothing it waits for can run it; Run now still does")
    }
}

extension WorkflowMode {
    /// Who gets the prompt, in words (#142).
    var words: String {
        switch self {
        case .new: "Starts a new agent each run"
        case .standing: "Sends each run to its standing agent"
        case .triggering: "Resumes the agent that triggered it"
        }
    }

    var symbol: String {
        switch self {
        case .new: "plus.circle"
        case .standing: "person.crop.circle"
        case .triggering: "arrow.uturn.backward.circle"
        }
    }
}

extension Workflow {
    /// The front-matter keys this version does not know, each as one line of what the
    /// file says (#142): a scalar as written, anything nested as JSON.
    var unknownLines: [String] {
        unknownFields.sorted { $0.key < $1.key }.map { key, value in
            let text: String
            switch value {
            case .string(let string): text = string
            case .null: text = "null"
            default: text = String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self)
            }
            return "\(key): \(text)"
        }
    }

    /// Whether its settings can be changed from a page: not while its file has a
    /// problem, because it then reads as empty settings and a change would write those
    /// over the file's own (#179). The daemon refuses such a write as well.
    var settingsLocked: Bool { problem != nil }

    /// What the pages say in place of the settings' notes while they are locked; the
    /// web page's words (#162).
    static let settingsLockedNote = "Its settings can be changed here once its file can be read."

    /// What the page says under a workflow's labels (#142).
    var labelsNote: String {
        if settingsLocked { return Self.settingsLockedNote }
        return settings.labels.isEmpty
            ? "No labels: each run's agent starts with none."
            : mode == .new
                ? "Each run's new agent gets these labels."
                : "Given to an agent this workflow starts; one it reuses keeps its own."
    }
}

extension MCPTriggerStatus {
    /// The line under the triggers (#383, contracts/wire-status.md), worked out at `now`
    /// from what the host last said, so "Checked 20 s ago" moves without the host
    /// sending anything. The web page's `workflows.ts` says the same words.
    func words(now: Date) -> (text: String, tint: StateTint) {
        let who = server ?? "its server"
        let body: String
        var tint = StateTint.none
        switch state {
        case .pending:
            body = failure?.message ?? "Connecting to \(who)…"
        case .active:
            let checked = lastPolledAt.map { "Checked \(Self.ago($0, now: now))" } ?? "Not checked yet"
            let last = lastEventAt.map { "last event \(Self.ago($0, now: now))" } ?? "no events yet"
            body = "\(checked) · \(last)"
        case .retrying:
            let again = retryAt.map { " · trying again in \(Self.span(max(0, $0.timeIntervalSince(now))))" } ?? ""
            if let failure, failure.code == .unreachable {
                body = "Can't reach \(who) since \(Self.clock(failure.since))\(again)"
            } else {
                body = (failure?.message ?? "Can't reach \(who)") + again
            }
            tint = .attention
        case .stopped:
            body = failure?.message ?? "Stopped"
            tint = .failure
        case .notThisHost:
            body = "Runs on another host, which asks for its events"
        }
        let lead = server.map { "\($0) · \(name)" } ?? name
        return ("\(lead): \(body)", tint)
    }

    /// "Events may have been missed since 09:14", while they may have been.
    var missedWords: String? {
        missedSince.map { "Events may have been missed since \(Self.clock($0))" }
    }

    static func ago(_ date: Date, now: Date) -> String {
        "\(span(max(0, now.timeIntervalSince(date)))) ago"
    }

    /// 20 s, 25 min, 3 h, 2 d.
    static func span(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole) s" }
        if whole < 3600 { return "\(whole / 60) min" }
        if whole < 86_400 { return "\(whole / 3600) h" }
        return "\(whole / 86_400) d"
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

extension WorkflowSummary {
    /// Arguments a server's event doesn't take, said where file errors are (#383).
    var mcpArgumentLines: [WorkflowStatusLine] {
        (mcpTriggers ?? []).filter { $0.failure?.code == .badArguments }.map {
            WorkflowStatusLine(symbol: "exclamationmark.triangle", text: $0.failure?.message ?? "",
                               detail: "The file is below", tint: .failure)
        }
    }
}
