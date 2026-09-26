import Foundation

/// Every sentence about retiring archived agents, in one place (051).
///
/// The Mac and the phone both draw rows, the retired page and the retired line, and here,
/// in the half both hold, they cannot say it two ways (`contracts/daemon-api.md`, Words).
public enum RetirementWords {
    // MARK: Pieces

    /// "12 October", in the person's calendar.
    public static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.day, .month], from: date)
        let month = calendar.monthSymbols[max(0, (parts.month ?? 1) - 1)]
        return "\(parts.day ?? 1) \(month)"
    }

    /// Bytes as Finder shows them: "584 MB".
    public static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    public static func capLabel(_ cap: RetentionSettings.Cap) -> String {
        cap.bytes.map { size($0) } ?? "No limit"
    }

    public static func keepForLabel(_ keep: RetentionSettings.KeepFor) -> String {
        switch keep {
        case .days7: return "7 days"
        case .days14: return "14 days"
        case .days30: return "30 days"
        case .days90: return "90 days"
        case .forever: return "Forever"
        }
    }

    static func agents(_ n: Int) -> String { n == 1 ? "1 archived agent" : "\(n) archived agents" }

    static func name(_ title: String?) -> String {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return "This agent"
        }
        return "\u{201C}\(title)\u{201D}"
    }

    // MARK: Rows

    /// What an archived row says under its title, or nothing. `cap` names the limit for
    /// the next-to-go note when the caller knows it.
    public static func rowNote(_ retirement: Retirement?, now: Date, cap: RetentionSettings.Cap? = nil,
                               calendar: Calendar = .current) -> String? {
        switch retirement {
        case .at(let due):
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                               to: calendar.startOfDay(for: due)).day ?? 0
            if days <= 0 { return "Retires today" }
            if days == 1 { return "Retires tomorrow" }
            return "Retires in \(days) days"
        case .nextUnderCap:
            if let cap, let bytes = cap.bytes { return "Next to be retired to stay under \(size(bytes))" }
            return "Next to be retired to stay under the limit"
        case .held(.worktreeHasWork):
            return "Kept: its worktree has work in it"
        case .held(.workflowRunning):
            return "Kept: a workflow run is still going"
        // Somebody is looking at it; a note about why would be noise. A first-day hold
        // is only ever reported for the whole archive.
        case .held(.openInWindow), .held(.firstDay), .unknown, nil:
            return nil
        }
    }

    /// The last line of a project's Archived list, or nothing.
    public static func retiredLine(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return count == 1 ? "1 older agent has been retired." : "\(count) older agents have been retired."
    }

    // MARK: The retired page and refusals

    /// What anything that leads to a retired agent says about it.
    public static func retiredSentence(_ t: Tombstone, calendar: Calendar = .current) -> String {
        let on = "\(name(t.title)) was retired on \(day(t.retiredAt, calendar: calendar))"
        switch t.retiredBecause {
        case .age:
            let days = max(1, Int((t.retiredAt.timeIntervalSince(t.archivedAt) / 86_400).rounded()))
            return "\(on), \(days) \(days == 1 ? "day" : "days") after it was archived."
        case .cap:
            return "\(on), to keep archived agents within the space they may take."
        case .person:
            return "\(on), when you chose to retire it."
        }
    }

    /// Why Retire now is not open for an agent.
    public static func refusal(_ hold: Hold) -> String {
        switch hold {
        case .worktreeHasWork: return "Its worktree still has work in it that is not committed or merged."
        case .workflowRunning: return "A workflow run it belongs to is still going."
        case .openInWindow: return "It is open in a window or on a device."
        case .firstDay: return "It was archived less than a day ago."
        }
    }

    public static let notArchived = "Only an archived agent can be retired."

    // MARK: Settings

    public static func settingsSummary(archivedCount: Int, archivedBytes: Int,
                                       settings: RetentionSettings) -> String {
        let what = "\(agents(archivedCount)), \(size(archivedBytes))."
        if settings.isOff { return "\(what) Archived agents are kept forever." }
        switch (settings.keepFor.interval, settings.cap.bytes) {
        case (.some, .some(let cap)):
            return "\(what) Kept \(keepForLabel(settings.keepFor)), up to \(size(cap))."
        case (.some, nil):
            return "\(what) Kept \(keepForLabel(settings.keepFor)), with no limit on space."
        case (nil, .some(let cap)):
            return "\(what) Kept until they take more than \(size(cap))."
        case (nil, nil):
            return "\(what) Archived agents are kept forever."
        }
    }

    public static func overCapSentence(_ over: OverCap, cap: RetentionSettings.Cap) -> String {
        var sentence = "Archived agents are \(size(over.bytesOver)) over \(capLabel(cap))."
        let reasons: [(Hold, String, String)] = [
            (.worktreeHasWork, "is kept because its worktree has work in it",
             "are kept because their worktrees have work in them"),
            (.workflowRunning, "is kept because a workflow run is still going",
             "are kept because workflow runs are still going"),
            (.openInWindow, "is kept because it is open", "are kept because they are open"),
            (.firstDay, "was archived today and is kept for a day", "were archived today and are kept for a day"),
        ]
        for (hold, one, many) in reasons {
            if let n = over.holding[hold], n > 0 { sentence += " \(n) \(n == 1 ? one : many)." }
        }
        return sentence
    }

    /// The confirmation for a change of setting that retires agents at once. `upTo` when
    /// some may turn out to be held, which the preview cannot know.
    public static func confirmSettings(count: Int, bytes: Int, upTo: Bool = false) -> String {
        let n = upTo ? "up to \(agents(count))" : agents(count)
        return "This retires \(n) now and frees \(size(bytes)). Their conversations are deleted and cannot be brought back."
    }

    public static func confirmRetire(title: String?, bytes: Int) -> String {
        let quoted = name(title) == "This agent" ? "this agent" : name(title)
        return "Retire \(quoted)? Its conversation (\(size(bytes))) is deleted and cannot be brought back."
    }
}
