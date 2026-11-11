import AgentsKitCore
import SwiftUI

/// The words of Project Settings ▸ Work at Once and Sessions (#64, #120, #2886, #2928): one
/// copy for the Mac's sheet and the Remote's Project Settings page. The web page's are in
/// `Web/src/views/ProjectSettings.tsx`.
enum HelperLimitWords {
    static let workAtOnce = "Work at Once"
    static let sessions = "Sessions"

    static let helpers = "Helpers"
    /// Running, queued and total, from the policy (#4377). The web page's is `helpersNow` in
    /// `Web/src/model/projectSettings.ts`.
    static func helpersNow(_ limits: (running: Int, notArchived: Int, queued: Int)) -> String {
        "\(limits.running) running, \(limits.queued) queued, \(limits.notArchived) in total"
    }
    static let helpersNote = "Set in Settings ▸ Agents ▸ Policy, or for this project in Policy. "
        + "Running counts sessions in a turn: one that waits for an event holds no place, and runs again "
        + "when it wakes. A start past running waits in the queue; a start past queued or total is refused. "
        + "They count across all the project's folders, on every machine. A lead doesn't count; "
        + "the sessions it starts do."

    static let allowance = "Allowance spent"
    static let allowanceSwitch = "Helpers continue when the allowance is back"
    static let allowanceNote = "A session started by a session waits for the allowance and carries on "
        + "when it is back, as if you had chosen Continue. Off, it stops until you do."

    static let otherMachines = "Other machines"
    static let otherMachinesSwitch = "Agents may start sessions on my other machines without asking"
    static let otherMachinesNote = "On, a session here may start a session on another of your machines without "
        + "asking you first. The new session's chat still says which session started it, "
        + "and from which machine. Off, it asks you each time."

    static let archived = "Helpers archived"
    static let archivedSwitch = "Sessions may archive the sessions they started"
    static let archivedNote = "A session may archive only sessions it started, once their turn has ended, "
        + "and never your own sessions. Off, it asks you instead. You can bring any of them back."

    static let merged = "Pull request merged"
    static let mergedSwitch = "Archive a session when its pull request merges"
    static let mergedNote = "A session in a worktree is archived when the pull request from its branch merges, "
        + "once its turn has ended and its worktree has nothing uncommitted. Any other session "
        + "gets a line in its chat. This needs the github or gitlab connector in this folder. "
        + "You can bring any of them back."
}

/// One of the helpers' switches in `.agents/folder.json` (#64), back to nil when it is the
/// default. The folder's machine keeps the file; `save` sends the whole set to it.
struct HelperLimitSwitch: View {
    let limits: HelperLimits
    let title: String
    let disabled: Bool
    let isOn: (HelperLimits) -> Bool
    let set: (inout HelperLimits, Bool) -> Void
    let save: (HelperLimits) async -> Void

    var body: some View {
        Toggle(title, isOn: Binding(get: { isOn(limits) }, set: { on in
            var changed = limits
            set(&changed, on)
            Task { await save(changed) }
        }))
        .toggleStyle(.switch)
        #if os(macOS)
        .controlSize(.small)
        #endif
        .disabled(disabled)
    }
}
