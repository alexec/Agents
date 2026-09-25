import Foundation

/// The git worktree an agent was started in (030).
///
/// On the agent's record rather than looked up, because the worktree can go — removed by
/// hand, pruned — and the agent still has to know where it was and which project it
/// belongs to. Its project is `project`, not its `cwd`: a worktree is a second checkout
/// of the same work, and filing it as a project of its own would scatter one project's
/// agents across the sidebar.
public struct AgentWorktree: Codable, Hashable, Sendable {
    /// The folder's name, and what the agent's row shows.
    public var name: String
    /// The worktree's top folder. The agent's `cwd` is this, or the same subfolder of
    /// it that the project folder is of its repository.
    public var root: URL
    /// `agents/<name>` for one the app made; whatever it had for one chosen; nil when
    /// its HEAD is detached.
    public var branch: String?
    /// The project folder it was started from.
    public var project: URL
    /// The branch, or the commit when detached, a new worktree was made from. What
    /// "merged" is measured against when it is cleaned up. Nil for one chosen.
    public var base: String?
    /// Made by this app's start, rather than chosen from what was already there.
    public var madeByApp: Bool

    public init(name: String, root: URL, branch: String?, project: URL,
                base: String?, madeByApp: Bool) {
        self.name = name
        self.root = root
        self.branch = branch
        self.project = project
        self.base = base
        self.madeByApp = madeByApp
    }
}

/// Where a new agent should work, when it is not simply the project folder.
public enum WorktreeChoice: Codable, Hashable, Sendable {
    /// Make a fresh worktree, named from the prompt.
    case new
    /// A worktree of the same repository that is already there.
    case existing(URL)
    /// Make a fresh worktree on a branch that is already there: a local one not
    /// checked out anywhere, or one only a remote has, which git then tracks.
    case branch(String)
}

/// What a new worktree is called (030, research R3).
///
/// Taken from the prompt, because that is the only thing about the work there is when
/// the worktree has to be made, and because a name that says what the work is reads
/// in `git branch` and on a row. Plain ASCII, lower-case and hyphenated, because it is
/// both a folder name and a branch name, and every tool that shows either has to cope.
public enum WorktreeName {
    /// Every branch the app makes sits under this, so they sort together and never
    /// collide with the person's own.
    public static let branchPrefix = "agents/"
    /// Where they are made, from the top of the repository.
    public static let folder = ".agents/worktrees"
    public static let maxLength = 32
    static let wordLimit = 4

    /// Words that say nothing about the work.
    static let filler: Set<String> = [
        "a", "an", "the", "to", "of", "on", "in", "for", "and", "or", "with",
        "please", "can", "could", "you", "would", "we", "i", "me", "my",
        "this", "that", "it", "is", "be",
    ]

    public static func branch(for name: String) -> String { branchPrefix + name }

    /// The folder a worktree on someone's branch goes in: the branch, less the app's
    /// own prefix, with every `/` a `-`, so `feature/login` is `feature-login`.
    public static func folder(forBranch branch: String) -> String {
        let bare = branch.hasPrefix(branchPrefix) ? String(branch.dropFirst(branchPrefix.count)) : branch
        var name = ""
        for character in bare {
            let kept = character.isASCII && (character.isLetter || character.isNumber || "-_.".contains(character))
            let next: Character = kept ? character : "-"
            if next == "-", name.hasSuffix("-") { continue }
            name.append(next)
        }
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "branch" : trimmed
    }

    public static func from(prompt: String, now: Date = Date()) -> String {
        let folded = prompt.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
        let words = folded
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
            .map(String.init)
            .filter { !filler.contains($0) }
            .prefix(wordLimit)

        var name = ""
        for word in words {
            let longer = name.isEmpty ? word : name + "-" + word
            if longer.count > maxLength { break }
            name = longer
        }
        // One word longer than the limit is still a word: cut it rather than lose it.
        if name.isEmpty, let first = words.first { name = String(first.prefix(maxLength)) }
        if !name.isEmpty { return name }

        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "MMdd-HHmm"
        return "agent-" + stamp.string(from: now)
    }

    /// A worktree's name for a branch that already exists, such as a pull request's
    /// (038): the same rules as a name from a prompt, applied to the branch's last
    /// part, so `alex/fix-login` checks out as `fix-login`.
    public static func from(branch: String) -> String {
        let last = branch.split(separator: "/").last.map(String.init) ?? branch
        let words = last.lowercased()
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
            .map(String.init)
        var name = ""
        for word in words {
            let longer = name.isEmpty ? word : name + "-" + word
            if longer.count > maxLength { break }
            name = longer
        }
        if name.isEmpty, let first = words.first { name = String(first.prefix(maxLength)) }
        return name.isEmpty ? "pull-request" : name
    }

    /// The name itself when it is free, otherwise the first free `-2`, `-3`, …
    public static func next(after name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        var number = 2
        while taken.contains("\(name)-\(number)") { number += 1 }
        return "\(name)-\(number)"
    }
}
