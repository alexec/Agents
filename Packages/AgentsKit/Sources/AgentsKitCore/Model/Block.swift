import Foundation

/// What a `blocked` report waits on, and whether that has cleared (039).
///
/// Held on the report rather than on the agent, because a report already has the
/// lifecycle a block wants: the person's next prompt takes it away, a later report
/// replaces it, and it is written with the record. A block kept anywhere else would
/// need clearing on every one of those paths, and two copies of that rule drift.
///
/// It clears exactly once. `clearedAt` goes up in the same write that queues the
/// resume, so an agent is never resumed twice for one block — not when two agents it
/// waits on finish together, and not across a restart.
public struct Block: Codable, Hashable, Sendable {
    /// The agents it waits on, in the order it named them. Empty when it is waiting on
    /// something the app cannot see.
    public var waits: [Wait]
    /// When to resume it anyway, to look at something the app cannot see.
    public var checkAgainAt: Date?
    /// Whether the first of `waits` to end clears it, or only the last (#152). Nil is
    /// `all`, which is what every block before this was.
    public var wakeOn: WakeOn?
    public var clearedAt: Date?
    public var clearedBy: Clearing?

    public init(waits: [Wait] = [], checkAgainAt: Date? = nil, wakeOn: WakeOn? = nil,
                clearedAt: Date? = nil, clearedBy: Clearing? = nil) {
        self.waits = waits
        self.checkAgainAt = checkAgainAt
        self.wakeOn = wakeOn
        self.clearedAt = clearedAt
        self.clearedBy = clearedBy
    }

    /// Which of the agents waited on have to end before it clears.
    public enum WakeOn: String, Codable, Hashable, Sendable, CaseIterable {
        /// The first one to end.
        case any
        /// Every one.
        case all
    }

    /// How a block came to clear. A person's prompt is not here: it takes the whole
    /// report away, block and all.
    public enum Clearing: String, Codable, Hashable, Sendable {
        /// Every agent it waited on has finished — or, waking on any, the first has.
        case waits
        /// The time it asked to be checked on came.
        case time
        /// It was stopped or archived, and will not be resumed.
        case dropped
    }

    /// The range an agent may ask to be checked on in: long enough apart that it does
    /// not wake every few seconds, and short enough to cover an overnight CI run.
    public static let checkAgainMinutes = 1...1440

    /// The two refusals about a block's words, said once for the helper and the daemon.
    public static let onlyWithBlocked =
        "Nothing was recorded: waiting_on, wake_on and check_again_in_minutes only go with blocked."
    public static let unknownWakeOn = "Nothing was recorded: wake_on has to be any or all."

    public var isOpen: Bool { clearedAt == nil }

    /// Every agent it waited on has ended. True of no waits at all, which is why
    /// `shouldResume` asks for at least one.
    public var allWaitsClosed: Bool { waits.allSatisfy { $0.ending != nil } }

    /// The agents it waited on have ended as far as it asked: the first of them, when it
    /// wakes on any, and every one otherwise. False of no waits at all.
    public var waitsCleared: Bool {
        guard !waits.isEmpty else { return false }
        return wakeOn == .any ? waits.contains { $0.ending != nil } : allWaitsClosed
    }

    public func isDue(now: Date) -> Bool {
        checkAgainAt.map { $0 <= now } ?? false
    }

    /// The whole rule for resuming. A block that named nobody and gave no time is
    /// never resumed by the app: it waits for the person.
    public func shouldResume(now: Date) -> Bool {
        isOpen && (waitsCleared || isDue(now: now))
    }
}

/// One agent a blocked agent waits on.
public struct Wait: Codable, Hashable, Sendable {
    /// Always an id, even when the agent named it by title.
    public var agentID: UUID
    /// Its title when the block was made, for when it has gone by the time anybody reads
    /// about it.
    public var nameAtReport: String
    /// Nil while it is still going. Set once, when it ends, and copied then: what it
    /// said may change afterwards, and the blocked agent is owed what it said at the
    /// time.
    public var ending: WaitEnding?

    public init(agentID: UUID, nameAtReport: String, ending: WaitEnding? = nil) {
        self.agentID = agentID
        self.nameAtReport = nameAtReport
        self.ending = ending
    }
}

/// How an agent that was waited on came to end.
public struct WaitEnding: Codable, Hashable, Sendable {
    public var at: Date
    public var how: How

    public init(at: Date, how: How) {
        self.at = at
        self.how = how
    }

    public enum How: Codable, Hashable, Sendable {
        /// Its turn ended. The outcome and message are what it reported, if it did.
        case finished(outcome: WorkOutcome?, message: String?)
        /// Stopped short, by the person, another agent or a failure.
        case stopped(EndedReason?)
        case archived
        /// No longer in the daemon's record at all.
        case gone
    }

    /// A few words for a row and a prompt: how it ended, without the message.
    public var summary: String {
        switch how {
        case .finished(let outcome, _):
            return outcome.map { "finished: \($0.heading.lowercased())" }
                ?? "finished without saying how it went"
        case .stopped(let reason): return reason?.summary?.lowercased() ?? "stopped"
        case .archived: return "archived"
        case .gone: return "gone"
        }
    }

    /// The message it left, if any.
    public var message: String? {
        if case .finished(_, let message) = how { return message }
        return nil
    }
}

// MARK: Words

/// What the app says about a block, in one place so the Mac's row, the phone's card and
/// the prompt the agent reads cannot drift apart.
public extension Block {
    /// One line per agent waited on: its name, and whether it has finished.
    static func waitLine(name: String, ending: WaitEnding?) -> String {
        guard let ending else { return "\(name) — still working" }
        return "\(name) — \(ending.summary)"
    }

    /// Above the wait lines, when there is more than one: which of them it waits for.
    func wakeLine() -> String? {
        guard isOpen, waits.count > 1 else { return nil }
        return wakeOn == .any ? "Carries on when any of these finishes"
                              : "Carries on when all of these have finished"
    }

    /// When it will check again, if it asked to.
    func checkAgainLine() -> String? {
        guard isOpen, let checkAgainAt else { return nil }
        return "Checks again at \(checkAgainAt.formatted(date: .omitted, time: .shortened))"
    }

    /// What Carry on sends, as the person.
    static let carryOnPrompt = "I've cleared the block you were waiting on. Carry on."

    /// What the app sends when the block clears, as itself.
    ///
    /// Says why it cleared, names every agent it waited on with how each ended and what
    /// each said, and repeats what the agent said it was waiting on — the agent reading
    /// this may have been waiting for hours, and its own sentence is the shortest way
    /// back into what it was doing.
    func resumePrompt(message: String, name: (Wait) -> String, why: Clearing) -> String {
        var lines: [String] = []
        let anyOf = wakeOn == .any && waits.count > 1
        switch why {
        case .waits where anyOf:
            lines.append("The block you reported has cleared: you asked to carry on when any of "
                         + "the agents you were waiting on finished, and one has.")
        case .waits:
            lines.append(waits.count == 1
                ? "The block you reported has cleared: the agent you were waiting on has finished."
                : "The block you reported has cleared: every agent you were waiting on has finished.")
        case .time, .dropped:
            lines.append("The time you asked to check again has come.")
        }
        func line(_ wait: Wait) -> String {
            var line = "- \u{201C}\(name(wait))\u{201D} (id \(wait.agentID.uuidString)): "
            if let ending = wait.ending {
                line += ending.summary
                if let said = ending.message { line += " — \(said)" }
            } else {
                line += "still working"
            }
            return line
        }
        let ended = waits.filter { $0.ending != nil }
        let going = waits.filter { $0.ending == nil }
        if anyOf {
            // Two lists, so the agent can see at a glance what is left to wait on.
            if !ended.isEmpty {
                lines.append("")
                lines.append("Finished:")
                lines.append(contentsOf: ended.map(line))
            }
            if !going.isEmpty {
                lines.append("")
                lines.append("Still running:")
                lines.append(contentsOf: going.map(line))
            }
        } else if !waits.isEmpty {
            lines.append("")
            lines.append(contentsOf: waits.map(line))
        }
        lines.append("")
        lines.append("You said you were waiting on: \(message)")
        if why == .waits {
            lines.append(going.isEmpty ? "Carry on from here."
                                       : "Carry on from here. To wait on the rest, end your turn blocked "
                                         + "again, naming them in waiting_on.")
        } else {
            lines.append("Check on it, and carry on or end your turn blocked again.")
        }
        return lines.joined(separator: "\n")
    }
}
