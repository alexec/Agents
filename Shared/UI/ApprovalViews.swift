import AgentsKitCore
import SwiftUI

/// One thing waiting for the person's OK in Needs You (#773): an MCP server, a workflow, a
/// plugin or a guarded file, drawn as a session's row is (#587) — the mark, the title, the
/// time and one grey line — with the same orange shield for every kind, so "needs
/// approving" reads the same whatever it is. (A request's row, below, has a mark for each
/// kind instead.) The window and the Remote both draw it.
struct ApprovalRowLabel: View {
    let approval: Approval
    /// Which folder it is in, after the title, as a smart group's rows name theirs.
    var place: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ApprovalMark(kind: approval.kind)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(approval.title)
                        .appText(.supporting)
                        .lineLimit(1)
                    if let place {
                        Text(place)
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                            .layoutPriority(-1)
                    }
                }
                Text("\(approval.kindWord) · \(approval.line)")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let since = approval.since { ActivityTime(date: since) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(approval.kind == .workflowFailed ? "stopped working" : "waiting for your approval")
    }
}

/// One request to the person in Needs You (#3864): what is asked, as its title, then its
/// kind, who asked it and how many sessions it blocks, and how long it has waited. A
/// secret's use (#4017) says which secret, who wants it and where its value goes; never the value. Drawn as
/// an approval's row is, its mark in the attention tint. Unlike an approval's, the mark is
/// one for each kind (`NeedRequest.symbol`, #4026), so it says what is asked; the web's
/// RequestRow.tsx draws the same marks. The window and the Remote both draw it.
struct RequestRowLabel: View {
    let request: NeedRequest
    /// The asker's name, as its session row says it.
    var asker: String?
    /// Which folder it is in, after the title, as a smart group's rows name theirs.
    var place: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: request.symbol)
                .sidebarMark(StateTint.attention.style(or: .primary))
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(request.title(asker: asker))
                        .appText(.supporting)
                        .lineLimit(1)
                    if let place {
                        Text(place)
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                            .layoutPriority(-1)
                    }
                }
                Text(request.line(asker: asker))
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            ActivityTime(date: request.askedAt)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue("waiting for your answer")
    }
}

/// The mark every approval row wears: a shield in the attention tint, as a workflow
/// waiting for an OK has worn (#587); a failed workflow (#989), the triangle its own row
/// wears on its folder's page.
struct ApprovalMark: View {
    var kind: Approval.Kind?

    var body: some View {
        Image(systemName: kind == .workflowFailed ? "exclamationmark.triangle" : "checkmark.shield")
            .sidebarMark(StateTint.attention.style(or: .primary))
            .frame(width: 16)
            .accessibilityHidden(true)
    }
}
