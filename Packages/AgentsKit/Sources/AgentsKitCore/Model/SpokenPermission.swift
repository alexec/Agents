import Foundation

/// An agent's request for permission, read out and answered by voice (#2358).
///
/// Only a low-risk request can be answered by voice: a read, a search, or an edit inside
/// the agent's own worktree. It is allowed once only, never "always". Anything else (a
/// command, a delete, a push or a merge, an edit outside a worktree, money) needs the
/// screen, and voice mode says so. A plan the agent asks to start on is read as its number
/// of steps and the first two, then "Approve the plan?".
public struct SpokenPermission: Hashable, Sendable {
    /// What the person's words mean.
    public enum Answer: Hashable, Sendable {
        case allow(optionID: String)
        case reject(optionID: String)
    }

    /// What is said.
    public var sentences: [String]
    /// Whether voice can answer it. When false, `sentences` ends with "This one needs your screen."
    public var isAnswerable: Bool { allow != nil }
    public var isPlan: Bool
    private var allow: String?
    private var reject: String?

    public static let needsTheScreen = SpokenQuestion.needsTheScreen
    public static let notCaught = "Say yes or no."

    /// `who`: the runtime's name, as "Claude". `worktree`: the agent's folder when it works
    /// in a worktree of its own; an edit inside it is low risk.
    public init(_ request: PermissionRequest, who: String, worktree: URL?) {
        let call = request.toolCall
        isPlan = call.isPlanApproval
        let allowOnce = request.options.first { $0.kind == .allowOnce }
        let rejectOnce = request.options.first { $0.kind == .rejectOnce }
            ?? request.options.first { $0.kind == .rejectAlways }
        if isPlan {
            sentences = Self.planSentences(call.planText)
        } else {
            let what = Speakable.text(call.line).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            sentences = ["\(who) asks to \(Self.lowercasingFirst(what))."]
        }
        guard let allowOnce, let rejectOnce, isPlan || Self.isLowRisk(call, worktree: worktree) else {
            allow = nil
            reject = nil
            sentences.append(Self.needsTheScreen)
            return
        }
        allow = allowOnce.optionID
        reject = rejectOnce.optionID
        sentences.append(isPlan ? "Approve the plan?" : "Allow it once?")
    }

    /// The answer the words mean, or nil.
    public func answer(for heard: String) -> Answer? {
        guard let allow, let reject else { return nil }
        let words = Set(SpokenQuestion.words(heard))
        let no = !words.isDisjoint(with: ["no", "nope", "deny", "don't", "reject", "not", "stop", "cancel"])
        let yes = !words.isDisjoint(with: ["yes", "yeah", "yep", "allow", "ok", "okay", "sure", "approve",
                                           "approved", "go", "fine", "do"])
        if no { return .reject(optionID: reject) }
        if yes { return .allow(optionID: allow) }
        return nil
    }

    // MARK: Risk

    /// Kinds of call that only look: read, search, fetch, think.
    static let looking: Set<String> = ["read", "search", "fetch", "think"]
    /// Words in a call's title that make it high risk, whatever its kind.
    static let risky = ["delete", "remove", "rm ", "push", "merge", "force", "drop", "deploy",
                        "pay", "purchase", "buy", "sudo", "reset --hard"]

    /// A read or search, or an edit whose every file is inside `worktree`.
    public static func isLowRisk(_ call: ToolCall, worktree: URL?) -> Bool {
        let title = (call.title + " " + call.line).lowercased()
        guard !risky.contains(where: title.contains) else { return false }
        let kind = call.kind ?? ""
        if looking.contains(kind) { return true }
        guard kind == "edit", let worktree else { return false }
        let root = worktree.standardizedFileURL.path.hasSuffix("/")
            ? worktree.standardizedFileURL.path : worktree.standardizedFileURL.path + "/"
        let paths = call.locations.map(\.path) + call.diffs.map(\.path)
        return !paths.isEmpty && paths.allSatisfy {
            URL(fileURLWithPath: $0).standardizedFileURL.path.hasPrefix(root)
        }
    }

    // MARK: Plans

    /// "The plan has 5 steps. First: … Second: … Approve the plan?" (the last added by init).
    static func planSentences(_ text: String?) -> [String] {
        let steps = planSteps(text ?? "")
        guard !steps.isEmpty else { return ["The plan is on the screen."] }
        var said = [steps.count == 1 ? "The plan has one step." : "The plan has \(steps.count) steps."]
        for (index, step) in steps.prefix(2).enumerated() {
            said.append("\(index == 0 ? "First" : "Second"): \(step).")
        }
        return said
    }

    /// The plan's steps: its numbered items, else its second- and third-level headings,
    /// else its bullets.
    public static func planSteps(_ text: String) -> [String] {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        func items(_ pattern: Regex<(Substring, Substring)>) -> [String] {
            lines.compactMap { line in
                guard let match = line.wholeMatch(of: pattern) else { return nil }
                let step = Speakable.text(String(match.1)).trimmingCharacters(in: CharacterSet(charactersIn: ".: "))
                return step.isEmpty ? nil : step
            }
        }
        for pattern in [#/\d+[.)]\s+(.+)/#, #/#{2,3}\s+(.+)/#, #/[-*]\s+(.+)/#] {
            let found = items(pattern)
            if !found.isEmpty { return found }
        }
        return []
    }

    private static func lowercasingFirst(_ s: String) -> String {
        guard let first = s.first, first.isUppercase, !(s.dropFirst().first?.isUppercase ?? false) else { return s }
        return first.lowercased() + s.dropFirst()
    }
}

/// The line voice mode says when nothing was heard for a while during a turn (#2358):
/// "Still working. Running the tests."
public enum StillWorking {
    /// How long a silence is before it is said.
    public static let after: Duration = .seconds(45)

    public static func line(step: String?) -> String {
        guard let step else { return "Still working." }
        let what = Speakable.text(step).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return what.isEmpty ? "Still working." : "Still working. \(what)."
    }
}
