import Foundation

/// Move to Machine… (#3790) in the words the window's sheet says them, on the Mac and the
/// Remote (#4037); the web's are the same, in `Web/src/model/moveToMachine.ts`.
enum MoveToMachineWords {
    static let menu = "Move to Machine…"
    static let symbol = "arrow.right.circle"
    static let noTargets = "No other machine is online. Start one under Machines in the sidebar, then try again."
    static let folderLabel = "Folder there"
    static let folderPlaceholder = "The project’s folder there"
    static let folderHelp = "Leave the folder empty to use this project’s folder on that machine, or give an absolute path, such as /home/me/project."
    static let moving = "Moving…"
    /// Takes a move that stopped off the session's row (#4641).
    static let putAway = "Put away"

    /// A move under way, on the session's row (#4641): the branch's bytes once there are a
    /// megabyte or more of them, then the session itself.
    static func moving(to machine: String, sent: Int, total: Int, branchSent: Bool) -> String {
        if branchSent { return "Moving to \(machine): sending the session…" }
        guard total >= 1_000_000 else { return "Moving to \(machine): sending its branch…" }
        let size = { (n: Int) in Int64(n).formatted(.byteCount(style: .file)) }
        return "Moving to \(machine): sending its branch, \(size(sent)) of \(size(total))…"
    }
    /// The Remote's bar, where the whole title does not fit; the title goes over the machine.
    static let barTitle = "Move to Machine"

    static func title(_ title: String?) -> String {
        "Move “\(title ?? "this session")” to Another Machine"
    }

    /// What goes, and, while a turn runs, that it stops here.
    static func whatGoes(stops: Bool) -> String {
        let line = "Its branch goes there with its uncommitted changes, and the session goes on there with this conversation."
        return stops ? "\(line) Its turn stops here, and it carries on there." : line
    }
}
