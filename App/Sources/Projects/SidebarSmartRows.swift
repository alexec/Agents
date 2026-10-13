import AgentsKitCore
import SwiftUI

/// One thing waiting for an OK under Needs You (#773): an MCP server, a workflow, a plugin
/// or a guarded file. A click opens what it is, with Approve, Deny and, where an agent
/// made it, Request Changes; the menu answers at once.
struct ApprovalListRow: View {
    @Environment(AppModel.self) private var model
    let approval: Approval
    let project: ProjectKey
    let place: String?
    @State private var open = false

    var body: some View {
        ApprovalRowLabel(approval: approval, place: place)
            .onTapGesture { open = true }
            .help("\(approval.kindWord) · \(approval.line)")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open = true }
            .contextMenu {
                Button("Open…") { open = true }
                if approval.actions.contains(.approve) {
                    Button(approval.word(for: .approve)) { answerNow(.approve) }
                }
                if approval.actions.contains(.deny) {
                    Button(approval.word(for: .deny)) { answerNow(.deny) }
                }
                if approval.actions.contains(.requestChanges) {
                    Button(approval.word(for: .requestChanges) + "…") { open = true }
                }
            }
            .sheet(isPresented: $open) {
                ApprovalSheet(approval: approval, place: place,
                              read: { await model.readApproval(approval, for: project) },
                              answer: { action, digest, note in
                                  await model.answerApproval(approval, action, digest: digest, note: note, for: project)
                              })
            }
    }

    /// From the menu, of the version the row was drawn from: a later change is refused.
    private func answerNow(_ action: Approval.Action) {
        Task { await model.settleApproval(approval, action, for: project) }
    }
}

/// A smart group in the source list (#866): its symbol, its name, and how many it
/// lists, the count in the attention tint when somebody is waiting. Picked, the list
/// column lists it.
struct SmartSourceRow: View {
    let row: SidebarSmartRow
    let count: Int

    private var systemImage: String {
        switch row {
        case .pinned: "pin"
        case .needsYou: "exclamationmark.bubble"
        case .working: "gearshape.2"
        case .unread: "circle.inset.filled"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(Paper.accent)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(row.title)
                .lineLimit(1)
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .monospacedDigit()
                    .appText(.fine)
                    .foregroundStyle(row == .needsYou ? StateTint.attention.style(or: .secondary)
                                                      : AnyShapeStyle(.secondary))
            }
        }
        .appText(.supporting)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count > 0 ? "\(row.title), \(count)" : "\(row.title), none")
    }
}

/// How far in from the list's edge a group heading's trailing mark sits, so it lines up
/// with the trailing counts and times of the rows under it (#495).
enum SidebarHeading {
    static let trailingInset: CGFloat = 11
}

/// A row under a project that opens a page about it (#495): its workflows, or its
/// archive. One row each where they used to be folds inside the project's fold.
struct ProjectPageRow: View {
    let title: String
    let systemImage: String
    let item: SidebarItem
    /// Red when the page has something wrong to say, as an Activity row's (#753).
    var warns = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(warns ? StateTint.failure.style(or: .primary) : AnyShapeStyle(Paper.accent))
                .frame(width: 16)
                .accessibilityHidden(true)
            // White, as every row's title is (#587); nothing at its end, which is only
            // a session's, the count in its tooltip.
            Text(title)
                .lineLimit(1)
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
        }
        // The size of the rows around it, sessions and New Session alike.
        .appText(.supporting)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .sidebarInk(item)
        .tag(item)
    }
}

/// A page about all the work in the sidebar's Activity group (#495): its icon, in the
/// accent, before the row. Beside the row rather than a `Label`, whose title a sidebar
/// list draws in its own style (#155).
private struct ActivityIcon: ViewModifier {
    let systemImage: String
    /// Red when the page has something wrong to say (#587): the row has no figure at its
    /// end to colour, which is only a session's.
    var warns = false

    func body(content: Content) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(warns ? StateTint.failure.style(or: .primary) : AnyShapeStyle(Paper.accent))
                .frame(width: 16)
                .accessibilityHidden(true)
            content
        }
    }
}

extension View {
    func activityIcon(_ systemImage: String, warns: Bool = false) -> some View {
        modifier(ActivityIcon(systemImage: systemImage, warns: warns))
    }
}
