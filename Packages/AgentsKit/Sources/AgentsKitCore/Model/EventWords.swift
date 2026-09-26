import Foundation

/// Every sentence about events and waiting, in one place (042).
///
/// The agent reads the tool replies and the wake prompt and acts on them, and the
/// person reads the status line and the hint, so the words are part of the contract
/// (`contracts/event-tools.md`) and are tested as such. Here, in the half both platforms
/// hold, as `LeaseWords` is.
public enum EventWords {
    static func clock(_ date: Date) -> String { LeaseWords.clock(date) }

    /// The details written out for an agent: `number=41, branch=main`. `agent_title`
    /// stands in for the id it reads.
    static func detailsLine(_ event: Event) -> String {
        var details = event.details
        if let title = details.removeValue(forKey: "agent_title") { details["agent"] = title }
        return details.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
    }

    // MARK: wait_for_event

    public static func matched(_ event: Event, waited: Int? = nil) -> String {
        let after = waited.map { " after waiting \($0) s" } ?? ""
        let details = detailsLine(event)
        return "\(event.name) happened at \(clock(event.at)) (position \(event.position))\(after): "
            + "\(event.sentence)\(details.isEmpty ? "" : ". \(details)")\(messageLine(event)). You can carry on."
    }

    public static func stillWaiting(_ wait: EventWait) -> String {
        let until = wait.deadline.map { ", until \(clock($0))" } ?? ""
        return "Still waiting for \(wait.label), since \(clock(wait.since))\(until). Your place is kept; "
            + "you can end your turn. You'll be started again when it happens."
    }

    public static func replaced(_ previous: EventWait) -> String {
        "Replaced your earlier wait on \(previous.label). "
    }

    public static let otherProject = "You can only wait on this project's events and this Mac's."

    public static func badDeadline() -> String {
        "until_minutes has to be from \(EventWait.deadlineMinutes.lowerBound) to \(EventWait.deadlineMinutes.upperBound)."
    }

    public static let nothingNamed = "Say what to wait for in events, e.g. [\"pull_request.checks_passed\"]. "
        + "wait_for_event with action \"list\" gives every name."

    /// One line of `action: recent`.
    public static func recentLine(_ event: Event) -> String {
        let details = detailsLine(event)
        let count = event.count > 1 ? " ×\(event.count)" : ""
        return "\(event.position) · \(clock(event.at)) · \(event.name)\(count) · \(event.sentence)"
            + (details.isEmpty ? "" : " · \(details)")
    }

    public static func recentFooter(head: EventPosition) -> String {
        "Head: \(head) — wait with from: \(head) to catch anything after this."
    }

    public static let noRecent = "Nothing has happened in this project or on this Mac yet."

    // MARK: The wake prompt

    public static func wake(_ event: Event, extraMatches: Int) -> String {
        var lines = ["The event you were waiting for happened.", "",
                     "\(event.name) at \(clock(event.at)) (position \(event.position))", event.sentence]
        for (key, value) in event.details.sorted(by: { $0.key < $1.key }) where key != "agent_title" {
            lines.append("\(key): \(key == "agent" ? event.details["agent_title"].map { "\($0) (\(value))" } ?? value : value)")
        }
        if let publisher = event.publisher { lines.append("published by: \(publisher.title)") }
        if let message = event.message { lines.append("message: \(message)") }
        if extraMatches > 0 {
            let more = extraMatches == 1 ? "1 more match arrived" : "\(extraMatches) more matches arrived"
            lines += ["", "\(more) before you resumed; wait_for_event with action \"recent\" to see "
                      + (extraMatches == 1 ? "it." : "them.")]
        }
        return lines.joined(separator: "\n")
    }

    public static func timedOut(_ wait: EventWait, at: Date) -> String {
        "Your wait for \(wait.label) timed out at \(clock(at)) with no match."
    }

    /// Put before the person's own words, in what the runtime receives, when their
    /// prompt took the place of a wait (FR-013). Never in their bubble.
    public static func cancelledByPrompt(_ wait: EventWait) -> String {
        "(Your wait for \(wait.label) was cancelled by this message. Wait again if you still need to.)"
    }

    /// The runtime note in the transcript of an agent that could not be started again.
    public static func couldNotWake(_ event: Event?, reason: String) -> String {
        guard let event else { return "Could not be started again when its wait ended: \(reason)." }
        return "Missed \(event.name) at \(clock(event.at)) (\(event.sentence)): could not be started again, \(reason)."
    }

    // MARK: cancel_wait

    public static func stoppedWaiting(_ wait: EventWait) -> String { "Stopped waiting for \(wait.label)." }
    public static let notWaiting = "You weren't waiting on anything."

    /// What an open call hears when the wait it made goes some other way.
    public static func ended(_ wait: EventWait, by canceller: EventWaitEnding.Canceller) -> String {
        switch canceller {
        case .agent: return stoppedWaiting(wait)
        case .person: return "The person cancelled your wait for \(wait.label)."
        case .prompt: return "The person sent you a message, which cancelled your wait for \(wait.label)."
        case .stopped: return "You were stopped, which ended your wait for \(wait.label)."
        case .archived: return "You were archived, which ended your wait for \(wait.label)."
        }
    }

    // MARK: publish_event

    public static func published(_ event: Event) -> String {
        var woke: [String] = [], fired: [String] = [], refused: [String] = []
        for consequence in event.consequences {
            switch consequence {
            case .woke(_, let title): woke.append(LeaseWords.agentName(title))
            case .fired(let workflowID, _, _): fired.append(workflowID)
            case .refused(let workflowID, _, let reason): refused.append("\(workflowID) (\(reason.message))")
            case .couldNotWake(_, let title, _): woke.append("\(LeaseWords.agentName(title)) could not be woken")
            }
        }
        var parts = ["Published \(event.name) (position \(event.position))."]
        if woke.isEmpty && fired.isEmpty && refused.isEmpty {
            parts.append("Nobody was waiting on it and no workflow triggers on it.")
        }
        if !woke.isEmpty { parts.append("Woke \(woke.joined(separator: ", ")).") }
        if !fired.isEmpty { parts.append("Fired workflow \(fired.joined(separator: ", ")).") }
        if !refused.isEmpty { parts.append("Refused by \(refused.joined(separator: ", ")).") }
        return parts.joined(separator: " ")
    }

    public static func publishOutsideCustom(_ name: String) -> String {
        "Only custom.* events can be published; \(name) is raised by the app."
    }

    public static func publishLimit(_ limit: Int, until: Date) -> String {
        "You've published \(limit) events in the last hour, which is the limit. Try again after \(clock(until))."
    }

    // MARK: The briefing

    /// The paragraph every agent is briefed with (042): wait rather than poll, the turn
    /// may end while waiting, publish to tell others, and where the names are.
    public static let briefing = """
        Wait for something to happen (checks passing, an agent finishing, this Mac waking) \
        with wait_for_event rather than checking again and again; if told you are still \
        waiting, you may end your turn and will be started again when it happens. Tell \
        others something happened with publish_event, using a custom. name.
        """

    // MARK: The person's side

    /// The line above the prompt bar while an agent waits: sending takes its place.
    public static func hint(_ wait: EventWait) -> String {
        "Sending will cancel the wait on \(wait.label)."
    }

    static func messageLine(_ event: Event) -> String {
        event.message.map { ". Message: \($0)" } ?? ""
    }
}
