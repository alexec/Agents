import Foundation

/// Every sentence about deleting archived agents, in one place (051, #398).
///
/// The Mac, the phone and the page all ask before deleting one, and here, in the half
/// the Mac and the phone both hold, they cannot say it two ways. The page's copy is in
/// `Web/src/views/SessionMenu.tsx`.
public enum DeletionWords {
    /// Bytes as Finder shows them: "584 MB".
    public static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    public static func keepForLabel(_ keep: RetentionSettings.KeepFor) -> String {
        switch keep {
        case .days7: return "7 days"
        case .days14: return "14 days"
        case .days30: return "30 days"
        case .days90: return "90 days"
        case .forever: return "Never"
        }
    }

    static func agents(_ n: Int) -> String { n == 1 ? "1 archived agent" : "\(n) archived agents" }

    // MARK: Delete

    /// The confirmation's title: "Delete “Fix the build”?".
    public static func confirmTitle(_ title: String?) -> String {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return "Delete this session?"
        }
        return "Delete \u{201C}\(title)\u{201D}?"
    }

    public static let confirmMessage = "Its conversation and record are removed. This cannot be undone."

    /// Why Delete is refused for an agent.
    public static func refusal(_ hold: Hold) -> String {
        switch hold {
        case .worktreeHasWork: return "Its worktree still has work in it that is not committed or merged."
        case .workflowRunning: return "A workflow run it belongs to is still going."
        case .openInWindow: return "It is open in a window or on a device."
        }
    }

    public static let notArchived = "Only an archived session can be deleted. Archive it first."

    // MARK: Delete a folder (#677)

    /// "Delete “Agents”?": the folder's name as its row shows it, host and all.
    public static func folderConfirmTitle(_ label: String) -> String {
        "Delete \u{201C}\(label)\u{201D}?"
    }

    public static let folderConfirmMessage = "Every session in it is deleted, with its conversation and record, "
        + "and the folder leaves the list. Its folder and files are not touched. This cannot be undone."

    public static let folderNotArchived = "Only an archived folder can be deleted. Archive it first."

    /// A session in it is still going: what stops the whole folder being deleted.
    public static let folderLive = "It is still working. Stop it first."

    /// Why a folder's Delete is refused: the sessions that hold it, and why.
    public static func folderRefusal(_ titles: [String?], because: String) -> String {
        let named = titles.map { title -> String in
            guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                return "a session"
            }
            return "\u{201C}\(title)\u{201D}"
        }
        let who = named.count == 1 ? named[0] : named.dropLast().joined(separator: ", ") + " and " + named.last!
        let first = who.prefix(1).uppercased() + who.dropFirst()
        return "\(first) cannot be deleted. \(because)"
    }

    /// What names an agent that has been deleted: a pin, a starter, an event.
    public static let deletedSession = "a deleted session"

    // MARK: Settings

    public static func settingsSummary(archivedCount: Int, archivedBytes: Int,
                                       settings: RetentionSettings) -> String {
        let what = "\(agents(archivedCount)), \(size(archivedBytes))."
        guard settings.keepFor.interval != nil else { return "\(what) Archived agents are kept until you delete them." }
        return "\(what) Each is deleted \(keepForLabel(settings.keepFor)) after it was archived."
    }

    /// The confirmation for a change of setting that deletes agents at once.
    public static func confirmSettings(count: Int, bytes: Int) -> String {
        "This deletes \(agents(count)) now and frees \(size(bytes)). Their conversations are deleted and cannot be brought back."
    }
}

/// Archive… on a folder's menu, asked first on the phone and the page (#668). The page's
/// copy is in `Web/src/views/Sidebar.tsx`.
public enum FolderArchiveWords {
    /// "Archive “devbox:Agents”?".
    public static func confirmTitle(_ label: String) -> String {
        "Archive \u{201C}\(label)\u{201D}?"
    }

    public static let confirmMessage = "It moves to Archived folders with its sessions, and its workflows stop. "
        + "Unarchive returns it. Its folder and files are not touched."
}
