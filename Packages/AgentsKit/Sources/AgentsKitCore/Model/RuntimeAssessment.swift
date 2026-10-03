import Foundation

/// Assessing a runtime (#47): an agent on it is given a fixed series of steps, one per
/// group of the app's tools, and the daemon scores what it did from its own record.
///
/// The steps and the brief live here, in the half every surface holds, so the Mac, the
/// Remote and the web page start the same assessment, and the skill in
/// `.agents/skills/assess-runtime/` names the same step ids (a test keeps them in step).
/// The scoring is a pure function of the record, tested without a daemon: the agent's
/// report is its own account, and is never what decides a pass.
public enum RuntimeAssessment {
    /// On every assessing agent, from its first moment. The daemon scores an agent that
    /// carries it each time it finishes.
    public static let label = "assess-runtime"
    /// On the helper the assessing agent starts.
    public static let helperLabel = "assess-runtime-helper"
    /// Published and waited for (step `events`).
    public static let pingEvent = "custom.assess_ping"
    /// Waited for and never published, so the wait times out (step `wait`).
    public static let neverEvent = "custom.assess_never"

    /// One step, by its id: what the agent does, and what the record must show.
    public struct Step: Hashable, Sendable, Identifiable {
        public var id: String
        public var area: String
        public var passesWhen: String
    }

    /// In the order the brief gives them.
    public static let steps: [Step] = [
        Step(id: "show_file", area: "Files",
             passesWhen: "show_file opened the report before it existed, and the report is there at the end"),
        Step(id: "leases", area: "Leases",
             passesWhen: "lease_resource, list_resources and release_resource answered; granted then released on the log; nothing left held"),
        Step(id: "workflows", area: "Workflows",
             passesWhen: "manage_workflows answered a list"),
        Step(id: "dashboard", area: "Dashboard",
             passesWhen: "set_tile, read_dashboard and remove_tile all answered"),
        Step(id: "events", area: "Events",
             passesWhen: "custom.assess_ping is on the log from this agent, and its wait came back with it"),
        Step(id: "ask_form", area: "Questions",
             passesWhen: "ask_form with a choice and a text field was answered, and the text came back to the agent unchanged and into the report"),
        Step(id: "own_ask", area: "Questions",
             passesWhen: "a question asked with the runtime's own tool reached the app and was answered (not offered where the runtime has none)"),
        Step(id: "helpers", area: "Helpers",
             passesWhen: "start_agent made a helper marked as this agent's; the agent was resumed when it finished; it was parked, then archived by this agent"),
        Step(id: "wait", area: "Events",
             passesWhen: "wait_for_event with until_minutes timed out, and the agent was started again to be told"),
        Step(id: "ending", area: "Ending a turn",
             passesWhen: "finish_turn recorded blocked on the helper, blocked with a check-again time, and a last done or needs_answer, with a title and a next prompt; no turn ended without an account"),
        Step(id: "report", area: "Self-report",
             passesWhen: "the report is at its path and names every step"),
    ]

    /// Where the report goes, in the project: `.agents/reviews/runtimes/<runtime>-<date>.md`.
    public static func reportPath(project: URL, runtimeID: String, date: Date,
                                  calendar: Calendar = .current) -> URL {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        let stamp = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        return project.appendingPathComponent(".agents/reviews/runtimes/\(runtimeID)-\(stamp).md")
    }

    /// The cheapest model a runtime offers, by the first of these words any of its models
    /// carries, in this order. The nightly runtime check (#39) uses the same list.
    public static let cheapWords = ["haiku", "nano", "flash-lite", "lite", "mini", "flash", "small"]

    /// The value to start the model option with, or nil for the runtime's own default.
    public static func cheapestModel(in options: [ConfigOption]) -> String? {
        guard let option = WorkflowSettings.modelOption(in: options) else { return nil }
        let choices = option.groups.flatMap(\.choices).compactMap { choice -> (String, String)? in
            guard let value = choice.value.stringValue else { return nil }
            return (value, "\(value) \(choice.name)".lowercased())
        }
        for word in cheapWords {
            if let hit = choices.first(where: { $0.1.contains(word) }) { return hit.0 }
        }
        return nil
    }

    /// The prompt the assessing agent is started with. The same steps as the skill.
    public static func brief(runtimeID: String, runtimeName: String, model: String?,
                             reportPath: String, escalationTool: String?, agentShortID: String,
                             date: String) -> String {
        let modelWords = model.map { "model `\($0)`" } ?? "its default model"
        let ownAsk = escalationTool.map {
            "Ask one question with your runtime's own question tool, `\($0)`, not `ask_form`: \"Is this assessment running unattended?\" with the options Yes and No."
        } ?? "Your runtime has no question tool the app can carry. Ask nothing here; write `not offered` for this step."
        let lease = "assess-\(agentShortID)"
        return """
            Assess the \(runtimeName) runtime (#47). Work through the steps below in order, in \
            this project. Each step uses the app's own tools, and the app scores every step from \
            its own record of what you called and what it answered — not from your report — so \
            do each one for real, exactly as written, even when you expect it to fail. If a tool \
            is refused or missing, say so in the report and go on to the next step. Change no \
            other file, make no commit, and run no commands.

            The report is `\(reportPath)`. Its table has one row per step, in this order, with \
            the step id in the first column: `show_file`, `leases`, `workflows`, `dashboard`, \
            `events`, `ask_form`, `own_ask`, `helpers`, `wait`, `ending`, `report`; then the \
            result (passed, failed or not offered) and the evidence: what the tool answered.

            **Turn 1**

            1. `show_file`: call `show_file` on the report before it exists, then write it: a \
            heading "\(runtimeName) assessment, \(date)", the runtime (`\(runtimeID)`) and model, \
            and the table. Update it after each step.
            2. `leases`: `lease_resource` named `\(lease)` for 5 minutes, then `list_resources`, \
            then `release_resource` `\(lease)`.
            3. `workflows`: `manage_workflows` with action `list`. Change nothing.
            4. `dashboard`: `set_tile` a status tile with id `assess-\(runtimeID)`, title \
            "\(runtimeName) assessment" and value "running"; then `read_dashboard`; then \
            `remove_tile` `assess-\(runtimeID)`.
            5. `events`: `wait_for_event` with action `recent` and limit 1, and note the position \
            it gives; `publish_event` `\(pingEvent)` with the message "ping"; then \
            `wait_for_event` on `\(pingEvent)` from that position. It comes back at once.
            6. `ask_form`: `ask_form` titled "\(runtimeName) assessment" with two questions: id \
            `pick`, prompt "Pick one", options `a` (Alpha) and `b` (Beta); and id `words`, prompt \
            "Type any short phrase", with no options. Write both answers into the report exactly \
            as they came back.
            7. `own_ask`: \(ownAsk)
            8. `helpers`: `start_agent` a helper on runtime `\(runtimeID)` with \(modelWords), the \
            label `\(helperLabel)`, and the prompt "Reply with the word OK, then call finish_turn \
            with outcome done and the message OK." Then call `list_my_agents`. End this turn with \
            `finish_turn`: outcome `blocked`, `waiting_on` the helper's id, title \
            "Assess \(runtimeName)", a message saying you are waiting on the helper, and a \
            `next_prompt`. You are started again when the helper finishes. (If that call is \
            refused because the helper has already finished, go straight on to step 9 in \
            this turn.)

            **Turn 2**, once the helper has finished

            9. `helpers`: `park_agent` the helper, then `archive_agent` it.
            10. `wait`: `wait_for_event` on `\(neverEvent)` with `until_minutes` 1. When it says \
            you are still waiting, end the turn with `finish_turn`, outcome `blocked`, saying you \
            are waiting for the wait to time out. You are started again when it does. (If the \
            call itself comes back timed out, go straight on to step 11 in this turn.)

            **Turn 3**, once the wait has timed out

            11. `ending`: end the turn with `finish_turn`, outcome `blocked`, \
            `check_again_in_minutes` 1, saying you will check again in a minute.

            **Turn 4**

            12. `report`: finish the report: every row filled in, and a section "What to fix" \
            naming each failure with its likely fix — the app, the adapter, the runtime's \
            version, or a setting. Then end with `finish_turn`: if every step passed by your \
            own account, outcome `done`, `afterwards` `park`, and a message saying how many \
            passed; otherwise outcome `needs_answer`, and a message for Alex naming the \
            failures and what to fix. The app then scores the record and adds its own table \
            to this conversation.
            """
    }
}

// MARK: - The score

/// What the daemon made of one assessment, from its own record (#47).
public struct RuntimeAssessmentScore: Codable, Hashable, Sendable {
    public enum Verdict: String, Codable, Hashable, Sendable {
        case passed, failed, notOffered = "not_offered"

        public var words: String {
            switch self {
            case .passed: "passed"
            case .failed: "**failed**"
            case .notOffered: "not offered"
            }
        }
    }

    public struct Check: Codable, Hashable, Sendable, Identifiable {
        public var id: String
        public var area: String
        public var verdict: Verdict
        public var evidence: String

        public init(id: String, area: String, verdict: Verdict, evidence: String) {
            self.id = id
            self.area = area
            self.verdict = verdict
            self.evidence = evidence
        }
    }

    public var agentID: UUID
    public var runtimeID: String
    public var model: String?
    public var scoredAt: Date
    public var reportPath: String?
    public var checks: [Check]

    public init(agentID: UUID, runtimeID: String, model: String?, scoredAt: Date,
                reportPath: String?, checks: [Check]) {
        self.agentID = agentID
        self.runtimeID = runtimeID
        self.model = model
        self.scoredAt = scoredAt
        self.reportPath = reportPath
        self.checks = checks
    }

    public var passed: Bool { !checks.contains { $0.verdict == .failed } }

    /// "9 of 11 passed; failed: own_ask; not offered: own_ask".
    public var summary: String {
        let passing = checks.filter { $0.verdict == .passed }.count
        let failed = checks.filter { $0.verdict == .failed }.map(\.id)
        let offered = checks.filter { $0.verdict == .notOffered }.map(\.id)
        var words = "\(passing) of \(checks.count) passed"
        if !failed.isEmpty { words += "; failed: " + failed.joined(separator: ", ") }
        if !offered.isEmpty { words += "; not offered: " + offered.joined(separator: ", ") }
        return words
    }

    /// The table, in Markdown, as the conversation shows it.
    public var table: String {
        var lines = ["| Step | Area | Result | From the app's record |", "| --- | --- | --- | --- |"]
        for check in checks {
            let evidence = check.evidence.replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\n", with: " ")
            lines.append("| `\(check.id)` | \(check.area) | \(check.verdict.words) | \(evidence) |")
        }
        return lines.joined(separator: "\n")
    }

    /// The note the daemon adds to the assessing agent's conversation.
    public var note: String {
        "The app scored this assessment of \(runtimeID) from its own record: \(summary).\n\n\(table)"
    }
}
