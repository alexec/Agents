import AgentsKitCore
import SwiftUI

/// One of the groups at the top of the sidebar (#495): Pinned, Needs You, Working or
/// Unread, across every project and host. A section headed and folding as a project's
/// is, so its heading and rows line up with theirs. Folded, it reads its count off each
/// project's shelf and lists nothing (#356). Empty, it is not drawn (#507).
struct SmartFold: View {
    @Environment(AppModel.self) private var model
    let row: SidebarSmartRow
    /// The projects in the sidebar, in its order.
    let projects: [ProjectKey]
    let folds: SidebarFolds
    /// The search's words, already trimmed; empty when there is no search.
    let query: String

    var body: some View {
        // Unread with nothing unread is still drawn while it keeps the open session.
        if row.isShown(in: model.work, projects: projects, query: query) || keptUnread != nil {
            fold
        }
    }

    private var fold: some View {
        let isOpen = folds.isOpen(row)
        let open = Binding(get: { isOpen }, set: { folds.set(row, open: $0) })
        let agents = isOpen ? shown : []
        return Section(isExpanded: open) {
            if row == .pinned {
                if isOpen { pinnedRows }
            } else {
                ForEach(FoldedRow.rows(agents, in: .smart(row))) { item in
                    SessionSidebarRow(agent: item.item, place: place(of: item.item))
                }
            }
        } header: {
            SmartRowLabel(row: row, count: row.count(in: model.work, projects: projects)) {
                open.wrappedValue.toggle()
            }
        }
    }

    /// What the row lists. Unread keeps the session opened from it (`keptInUnread`) in
    /// its place, read now, until another is opened: its count has already dropped.
    private var shown: [Agent] {
        var agents = row.agents(in: model.work, projects: projects, query: query)
        if let kept = keptUnread, !agents.contains(where: { $0.id == kept.id }) {
            let at = agents.firstIndex { $0.createdAt < kept.createdAt } ?? agents.endIndex
            agents.insert(kept, at: at)
        }
        return agents
    }

    /// The session Unread keeps, read, while it is the one open; none while searching.
    private var keptUnread: Agent? {
        guard row == .unread, query.isEmpty, let id = model.keptInUnread,
              let kept = model.work.agent(id), kept.state != .archived else { return nil }
        return kept
    }

    /// Every project's pinned sessions, then its pinned workflows, each dragged into the
    /// order wanted among its own project's and its own kind (#180, #432).
    @ViewBuilder
    private var pinnedRows: some View {
        let searching = !query.isEmpty
        ForEach(projects, id: \.self) { key in
            let sessions = SidebarSmartRow.pinned.agents(in: model.work, projects: [key], query: query)
            ForEach(FoldedRow.rows(sessions, in: .smart(.pinned))) { item in
                SessionSidebarRow(agent: item.item, place: place(of: item.item))
            }
            // The whole order, which a search shows only some of.
            .onMove { from, to in
                guard !searching else { return }
                var ids = sessions.map(\.id)
                ids.move(fromOffsets: from, toOffset: to)
                let shown = Set(ids)
                let rest = model.pinnedSessions(in: key.folder).filter { !shown.contains($0) }
                Task { await model.arrangeSessionPins(ids + rest, in: key) }
            }
            let flows = SidebarSmartRow.pinned.workflows(in: model.work, projects: [key], query: query).map(\.workflow)
            ForEach(FoldedRow.rows(flows, in: .smart(.pinned))) { item in
                WorkflowListRow(summary: item.item, project: key)
            }
            .onMove { from, to in
                guard !searching else { return }
                var ids = flows.map(\.workflowID)
                ids.move(fromOffsets: from, toOffset: to)
                let shown = Set(ids)
                let rest = model.pinnedWorkflows(in: key.folder).filter { !shown.contains($0) }
                Task { await model.arrangeWorkflowPins(ids + rest, in: key) }
            }
        }
    }

    /// The project's name as its row in the sidebar says it: `server:Project` on a server.
    private func place(of agent: Agent) -> String? {
        guard let summary = model.work.project(ProjectKey(host: agent.host, folder: agent.projectFolder)) else { return nil }
        return SidebarOrder.label(summary) { model.hosts.label($0) }
    }
}

/// A smart row's own line: its symbol, its name, and how many, the count in the
/// attention tint when somebody is waiting; absent at none, which only Unread keeping
/// the open session is drawn at.
private struct SmartRowLabel: View {
    let row: SidebarSmartRow
    let count: Int
    /// A click on the heading folds or unfolds it, as on a project's (#375).
    var onClick: () -> Void = {}

    var body: some View {
        // No icon (Alex, #495): the sessions under it carry the marks. Grey, as every
        // group's heading is.
        HStack(spacing: 6) {
            Text(row.title)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .monospacedDigit()
                    .appText(.fine)
                    .foregroundStyle(row == .needsYou ? StateTint.attention.style(or: .secondary)
                                                      : AnyShapeStyle(.secondary))
            }
        }
        // A heading runs to the list's edge, its rows stop short of it: this keeps the
        // count over the rows' counts and times (#495).
        .padding(.trailing, SidebarHeading.trailingInset)
        .appText(.supporting)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { onClick() })
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
    let count: Int
    let item: SidebarItem

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(Paper.accent)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(count)")
                .monospacedDigit()
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
        // The size of the rows around it, sessions and New Session alike.
        .appText(.supporting)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count)")
        .sidebarInk(item)
        .tag(item)
    }
}

/// A page about all the work in the sidebar's Activity group (#495): its icon, in the
/// accent, before the row. Beside the row rather than a `Label`, whose title a sidebar
/// list draws in its own style (#155).
private struct ActivityIcon: ViewModifier {
    let systemImage: String

    func body(content: Content) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(Paper.accent)
                .frame(width: 16)
                .accessibilityHidden(true)
            content
        }
    }
}

extension View {
    func activityIcon(_ systemImage: String) -> some View {
        modifier(ActivityIcon(systemImage: systemImage))
    }
}
