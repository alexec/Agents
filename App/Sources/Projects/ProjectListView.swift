import AgentsKit
import SwiftUI

/// The folders you work in, and nothing else.
///
/// This used to be every agent ever started. A list of folders is the length of the
/// work rather than the length of the history, which is the whole point of the change.
struct ProjectListView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    @AppStorage("showsArchivedProjects") private var showsArchived = false
    @State private var isChoosingFolder = false

    var body: some View {
        List(selection: $selection) {
            ForEach(model.liveProjects) { summary in
                ProjectRow(summary: summary)
                    .tag(SidebarItem.project(summary.folder))
                    .contextMenu { menu(for: summary) }
            }

            if !model.archivedProjects.isEmpty {
                Section(isExpanded: $showsArchived) {
                    ForEach(model.archivedProjects) { summary in
                        ArchivedProjectRow(summary: summary)
                    }
                } header: {
                    Text("Archived")
                }
            }

            if model.projects.isEmpty {
                EmptyProjectList(isChoosingFolder: $isChoosingFolder)
            }
        }
        .listStyle(.sidebar)
        // Carried over from the agent list this replaced: four agents running is four
        // numbers to add up in your head, which is the sort of thing you only do after
        // the bill. Pinned rather than scrolled with the projects: it is about all of
        // them, and a list long enough to scroll is exactly when you want it.
        .safeAreaInset(edge: .bottom) { SpendingRow(selection: $selection) }
        // Named only when it is not the ordinary daemon. Two copies of this app can
        // be running against two roots, and an unlabelled window is the one you
        // archive the wrong project in.
        .navigationTitle(StoreLocations.default.isStandard
                         ? "Projects"
                         : "Projects — \(StoreLocations.default.name)")
        .toolbar {
            // One button. Agents are started by telling a project what you want done,
            // so a button for starting one by hand would be a second way to do the
            // same thing, in the column that is not even about agents.
            ToolbarItem {
                Button {
                    isChoosingFolder = true
                } label: {
                    Label("New project", systemImage: "plus")
                }
                .help("Add a folder as a project")
            }
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result else { return }
            Task { await model.addProject(folder) }
        }
    }

    @ViewBuilder
    private func menu(for summary: DaemonAPI.ProjectSummary) -> some View {
        Button("Archive") {
            Task { await model.archiveProject(summary.folder) }
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([summary.folder])
        }
        .disabled(!summary.exists)
    }
}

/// An archived project, with when it was put away.
private struct ArchivedProjectRow: View {
    @Environment(AppModel.self) private var model
    let summary: DaemonAPI.ProjectSummary

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.name).lineLimit(1).foregroundStyle(.secondary)
                if let archivedAt = summary.project.archivedAt {
                    Text("Archived \(archivedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button("Unarchive") {
                Task { await model.unarchiveProject(summary.folder) }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .contextMenu {
            Button("Unarchive") {
                Task { await model.unarchiveProject(summary.folder) }
            }
        }
    }
}

/// The first thing anybody sees. It says what to do, not that something is wrong.
private struct EmptyProjectList: View {
    @Environment(AppModel.self) private var model
    @Binding var isChoosingFolder: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.availableRuntimes.isEmpty {
                Text("No agent runtime found")
                    .font(.headline)
                Text("Agents runs the coding CLIs you already have. Install one and it appears here.")
                    .foregroundStyle(.secondary)
                ForEach(model.runtimes) { status in
                    RuntimeMissingLine(status: status)
                }
            } else {
                Text("No projects yet")
                    .font(.headline)
                Text("A project is a folder you work in. Pick one and say what you want done.")
                    .foregroundStyle(.secondary)
                Button("Add a project") { isChoosingFolder = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 8)
    }
}

/// Why a runtime this app knows about is not usable, in the runtime's own terms.
private struct RuntimeMissingLine: View {
    let status: RuntimeStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(status.runtime.name).font(.callout.weight(.medium))
            switch status.availability {
            case .missing(let lookedIn):
                Text("Looked for \(status.runtime.executable) in \(lookedIn.prefix(4).joined(separator: ", "))…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .needsSignIn(_, let fixCommand):
                Text(fixCommand.map { "Signed out. Run \($0)." } ?? "Signed out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let reason):
                Text(reason).font(.caption).foregroundStyle(.secondary)
            case .available:
                EmptyView()
            }
        }
    }
}

/// The way into Spending, and what today has cost on the way past.
///
/// The bottom of this column has always been where the money is, so Spending is here
/// rather than in a row above the projects: a line that already shows a figure is the
/// one place somebody looks for more of it. It is a row of the sidebar and not a
/// button to a window of its own — the bill is something you read beside the work and
/// come back out of, like a project.
///
/// Today rather than "this sitting": today's figure is what the daily limit is
/// measured against, it survives closing the window, and it needs no baseline
/// subtracted from it. The meter in a chat says what one agent cost. Per currency,
/// like every other total here: two currencies read as two numbers rather than one
/// nobody could check.
///
/// Drawn whether or not anything has been spent, unlike the line it replaces. A row
/// that hides itself until the first pound is spent is a row nobody can use to find
/// out that nothing has been — and while the cost was going unbanked, it was the only
/// way in and it was never there.
private struct SpendingRow: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    private var isPicked: Bool { selection == .spending }

    var body: some View {
        Button {
            selection = .spending
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(today == nil ? "Spending" : "Today")
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    if let today {
                        Text(today).monospacedDigit()
                    }
                    // Nothing when there is no limit: headroom that does not exist is
                    // not a thing to draw an empty gauge for.
                    if let state = model.costState, let left = state.dayHeadroom,
                       let daily = state.limits.daily {
                        Text("\(left.formatted(.currency(code: daily.currency))) left")
                            .font(.caption2)
                    }
                }
            }
            .font(.footnote)
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isPicked ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
        .help(today == nil
              ? "What all of the work has cost"
              : "What every agent has cost today. Opens Spending.")
    }

    private var today: String? {
        model.costState.flatMap { Cost.total(of: $0.today) }
    }

    /// Colour means a person is needed. The app's existing threshold for a nearly full
    /// context, not a second number to learn. A picked row is drawn on the selection
    /// colour, where red on blue is neither legible nor a warning anybody reads.
    private var foreground: AnyShapeStyle {
        if isPicked { return AnyShapeStyle(.primary) }
        return model.costState?.dayIsCloseToFull == true
            ? AnyShapeStyle(.red)
            : AnyShapeStyle(.secondary)
    }
}
