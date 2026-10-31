import AgentsKitCore
import SwiftUI

/// What state a workflow is in, as one symbol.
///
/// Grey, all of it, except the one that wants you — the same rule the agent list
/// follows, and the reason it holds here is that most refusals resolve themselves.
struct WorkflowStatusIcon: View {
    let summary: WorkflowSummary
    /// The sidebar's (#495): in the accent rather than grey when it wants nobody, and
    /// the size of the other icons there.
    var accented = false

    var body: some View {
        Image(systemName: name)
            // The sidebar's icons are the size of its rows' text (#495); the page's larger.
            .appText(accented ? .supporting : .reading)
            .sidebarMark(summary.needsAPerson ? StateTint.attention.style(or: .secondary)
                         : accented ? AnyShapeStyle(Paper.accent) : AnyShapeStyle(.secondary))
            .accessibilityLabel(label)
    }

    private var name: String {
        if summary.isArchived { return "archivebox" }
        // A shield, not a hand (#587): the hand is a session's Needs You mark, and a
        // workflow waiting for an OK beside it read as one more session asking.
        if summary.awaitingApproval != nil { return "checkmark.shield" }
        if summary.deniedHere != nil { return "xmark.shield" }
        if !summary.isEnabled { return "pause.circle" }
        if summary.needsAPerson { return "exclamationmark.triangle" }
        // A bot's workflow heard here (#2027).
        if !summary.runsHere { return "ear" }
        if summary.isRunning { return "circle.dotted" }
        // Run only by hand (#432): nothing to wait for, and nothing wrong.
        if summary.workflow.runsOnlyByHand && summary.workflow.problem == nil { return "hand.tap" }
        if !summary.workflow.canFire { return "circle.dashed" }
        // An alarm clock for a schedule, a flowchart otherwise (#765): a plain clock read as
        // a session's Waiting.
        if summary.nextFireAt != nil { return "alarm" }
        return "flowchart"
    }

    private var label: String {
        if summary.isArchived { return "Archived" }
        if summary.awaitingApproval != nil { return "Waiting for your OK" }
        if summary.deniedHere != nil { return "Denied on this machine" }
        if !summary.isEnabled { return "Turned off" }
        if summary.overLimit != nil { return "Over the limit" }
        if summary.needsAPerson { return "Needs attention" }
        if let bot = summary.hearsFor { return "Heard for \(bot)" }
        if summary.isRunning { return "Running" }
        if summary.workflow.runsOnlyByHand && summary.workflow.problem == nil { return "Runs by hand" }
        if !summary.workflow.canFire { return "Not yet supported" }
        return "Waiting for its trigger"
    }
}
