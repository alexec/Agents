import Foundation

/// Every sentence about events and waiting, in one place (042).
///
/// The agent reads the tool replies and the wake prompt and acts on them, and the
/// person reads the status line and the hint, so the words are part of the contract
/// (`contracts/event-tools.md`) and are tested as such. Here, in the half both platforms
/// hold, as `LeaseWords` is.
public enum EventWords {
    static func clock(_ date: Date) -> String { LeaseWords.clock(date) }

    /// The details written out for an agent: `branch=main, from=…`, each named as the
    /// kind's `payloadSchema` names it (#579): `agent` is the id, `agent_title` its title.
    static func detailsLine(_ event: Event) -> String {
        event.details.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
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

    public static let otherFolder = "You can only wait on this folder's events and this Mac's."

    public static func badDeadline() -> String {
        "until_minutes has to be from \(EventWait.deadlineMinutes.lowerBound) to \(EventWait.deadlineMinutes.upperBound)."
    }

    /// A wait with no deadline, refused (#572): nothing else is sure to end it.
    public static func deadlineRequired() -> String {
        "until_minutes is required: say how long to wait, from \(EventWait.deadlineMinutes.lowerBound) minute "
            + "to 24 hours (\(EventWait.deadlineMinutes.upperBound)). When it runs out you are started again "
            + "and can wait again."
    }

    /// Names only a Mac raises, said on a host that is not one (#372).
    /// A wait on the default branch moving, refused (#702).
    public static func defaultBranchNotWatched(_ branch: String) -> String {
        "branch.moved is not raised for \(branch), the default branch: this Mac's copy moves only when someone "
            + "pulls. To wait for a pull request to land, wait for pr.merged (or pr.closed) with its pr. Nothing is waiting."
    }

    public static func neverHere(_ names: [String]) -> String {
        let one = names.count == 1
        return "\(names.joined(separator: ", ")) \(one ? "is" : "are") only raised on a Mac, and this machine is "
            + "a Linux server, so \(one ? "it never happens" : "they never happen") here."
    }

    // MARK: Servers' events in a wait (#577)

    /// The subscriptions a wait made, said first in its answer: "Subscribed to
    /// pr.merged on ci (repo alexec/Agents)."
    public static func subscribed(_ events: [WaitServerEvent]) -> String {
        let made = events.filter { !$0.servers.isEmpty }
        guard !made.isEmpty else { return "" }
        return "Subscribed to \(made.map(\.label).joined(separator: " and ")). "
    }

    /// No server here offers a name: refused, with what each server does offer, and the
    /// app's own name it may have meant.
    public static func notOffered(_ name: String, offers: [String: [String]]) -> String {
        var words = "No server here offers \(name)."
        for (server, names) in offers.sorted(by: { $0.key < $1.key }) {
            words += names.isEmpty ? " \(server) offers no events." : " \(server) offers \(names.joined(separator: ", "))."
        }
        if offers.isEmpty { words += " This folder has no MCP server that offers events." }
        if let guess = EventPatternProblem.closest(to: name) { words += " Did you mean \(guess)?" }
        return words
    }

    /// A name only servers that could not be asked might offer: kept, since they may come
    /// back, and subscribed to when they do.
    public static func serversMayComeBack(_ name: String, why: [String]) -> String {
        "\(name) could not be checked: \(why.joined(separator: " ")) The wait is kept, and subscribes when "
            + "the server can be asked; if it never offers \(name), this wait never ends. "
    }

    public static let nothingNamed = "Say what to wait for in events, e.g. [\"agent.finished\"]. "
        + "Unknown events and filters say what is offered."

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
            lines += ["", "\(more) before you resumed; they are in this folder's events."]
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Restarts (#1219)

    /// Whether what a pattern names is had again after a restart: a server's events
    /// replay from their cursor, `branch.moved` compares the saved tips, and the disk and
    /// the person are looked at again. Anything else that happened in the gap is gone.
    public static func caughtUpAfterRestart(_ name: String) -> Bool {
        if EventWait.isServerPattern(name) { return true }
        if name == "branch.moved" || name == "branch.*" { return true }
        guard let subject = EventSubject(name: name) else { return false }
        return [.system, .machine, .person].contains(subject)
    }

    /// Added to a wake, or a time-out, of a wait that was open over a restart: when, for
    /// how long, and what may be missing, so the agent knows to catch up.
    public static func restartNotice(_ gaps: [RestartGap], wait: EventWait) -> String {
        guard !gaps.isEmpty else { return "" }
        var lines = [""]
        for gap in gaps {
            let down: String
            if let since = gap.downSince {
                down = "It was down for about \(gap.downForWords) (from \(clock(since)))."
            } else {
                down = "How long it was down is unknown: nothing was recorded before it went."
            }
            lines.append("Agents restarted at \(clock(gap.at)) while you waited. \(down)")
        }
        let names = wait.patterns.map(\.name)
        let missing = names.filter { !caughtUpAfterRestart($0) }
        if missing.isEmpty {
            lines.append("What you wait on was caught up after it: \(names.joined(separator: ", ")).")
        } else {
            lines.append("Events in that time may be missing: \(missing.joined(separator: ", ")). Check the state yourself (for example the branch or the PR).")
        }
        return "\n" + lines.joined(separator: "\n")
    }

    public static func restartedSentence(_ gap: RestartGap) -> String {
        switch gap.reason {
        case .firstStart: return "Agents started."
        case .stopped: return "Agents restarted after a clean stop. It was down for \(gap.downForWords)."
        case .crashed: return "Agents restarted after it stopped unexpectedly. It was down for about \(gap.downForWords)."
        }
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
        case .person: return "The person cancelled your wait for \(wait.label). Check whether \(wait.label) happened anyway before you stop: the person may only be telling you to carry on without waiting, not that it did not happen."
        case .prompt: return "The person sent you a message, which cancelled your wait for \(wait.label)."
        case .stopped: return "You were stopped, which ended your wait for \(wait.label)."
        case .archived: return "You were archived, which ended your wait for \(wait.label)."
        case .archiveRequested: return "You asked to be archived, which ended your wait for \(wait.label)."
        }
    }

    // The paragraph every agent is briefed with (042) is the Go daemon's, eventsBrief in
    // Go/internal/agentsd/brief.go (#1801).

    static func messageLine(_ event: Event) -> String {
        event.message.map { ". Message: \($0)" } ?? ""
    }
}
