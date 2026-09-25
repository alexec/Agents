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
    @State private var isCloning = false

    var body: some View {
        List(selection: $selection) {
            ForEach(model.liveProjects) { summary in
                ProjectRow(summary: summary)
                    .tag(SidebarItem.project(summary.folder))
                    .contextMenu { menu(for: summary) }
            }
            // Where the project will be once it is one (027).
            ForEach(model.clones) { clone in
                CloningRow(clone: clone)
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

            if !model.isConnected {
                // Said rather than left to look like a quiet afternoon: what is listed
                // may have moved on, and the window is going back for it by itself.
                Text(model.hasLoadedProjects ? "Not connected to the daemon. Trying again…"
                                             : "Connecting…")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else if model.projects.isEmpty, model.clones.isEmpty, model.hasLoadedProjects {
                EmptyProjectList(isChoosingFolder: $isChoosingFolder, isCloning: $isCloning)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Paper.sidebar)
        // Carried over from the agent list this replaced: four agents running is four
        // numbers to add up in your head, which is the sort of thing you only do after
        // the bill. Pinned rather than scrolled with the projects: it is about all of
        // them, and a list long enough to scroll is exactly when you want it.
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                // Above Spending, and a row of its own rather than a second line
                // inside it: that row is a button into Spending, and why the Mac is
                // awake is not spending. It is absent entirely when there is nothing
                // to say, which is most of the time (024 FR-015).
                WakefulnessRow()
                // Above Spending (036): who holds the Mac's shared things. Always
                // there, like Spending, so the page can be found before anything is
                // leased; its count line is what comes and goes.
                // Above Resources (042): what happened. Always there, so the page can
                // be found before anything has; no count, because a record is read,
                // not something asking for attention.
                EventsRow(selection: $selection)
                ResourcesRow(selection: $selection)
                SpendingRow(selection: $selection)
            }
        }
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
            //
            // Two ways in, one button: a folder already on the Mac, or a repository
            // that is not yet (027).
            ToolbarItem {
                Menu {
                    Button("Choose Folder…") { isChoosingFolder = true }
                    Button("Clone Git URL…") { isCloning = true }
                } label: {
                    Label("New project", systemImage: "plus")
                }
                .help("Add a folder, or clone a repository, as a project")
            }
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result else { return }
            Task { await model.addProject(folder) }
        }
        .sheet(isPresented: $isCloning) { CloneSheet().paperSheet() }
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
                        .appText(.fine)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button("Unarchive") {
                Task { await model.unarchiveProject(summary.folder) }
            }
            .buttonStyle(.link)
            .appText(.fine)
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
    @Binding var isCloning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.availableRuntimes.isEmpty {
                Text("No agent runtime found")
                    .appText(.reading).fontWeight(.semibold)
                Text("Agents runs the coding CLIs you already have. Install one and it appears here.")
                    .foregroundStyle(.secondary)
                ForEach(model.runtimes) { status in
                    RuntimeMissingLine(status: status)
                }
            } else {
                Text("No projects yet")
                    .appText(.reading).fontWeight(.semibold)
                Text("A project is a folder you work in. Pick one and say what you want done.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Add a folder") { isChoosingFolder = true }
                        .buttonStyle(.borderedProminent)
                    Button("Clone a Git URL") { isCloning = true }
                }
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
            Text(status.runtime.name).appText(.reading).fontWeight(.medium)
            if let reason = status.unavailableReason {
                Text(reason).appText(.fine).foregroundStyle(.secondary)
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
                        Text("\(left.money(in: daily.currency)) left")
                            .appText(.fine)
                    }
                }
            }
            .appText(.fine)
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isPicked ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Paper.sidebar)
        .help(today == nil
              ? "What all of the work has cost"
              : "What every agent has cost today. Opens Spending.")
    }

    private var today: String? {
        model.costState.flatMap { Cost.total(of: $0.today) }
    }

    /// Colour means the limit is about to bite. The app's existing threshold for a
    /// nearly full context, not a second number to learn. A picked row is drawn on the
    /// selection colour, where red on blue is neither legible nor a warning anybody
    /// reads.
    private var foreground: AnyShapeStyle {
        if isPicked { return AnyShapeStyle(.primary) }
        return (model.costState?.dayIsCloseToFull == true ? StateTint.failure : .none)
            .style(or: .secondary)
    }
}

/// Why the Mac is not asleep, when it is not asleep because of us.
///
/// A machine behaving unusually with no visible cause is how an app loses the benefit of
/// the doubt. This is the whole of 024's answer to that: it connects two facts the person
/// can already see separately — an agent is working, and the Mac has not slept.
///
/// **Absent, not empty, when there is nothing to say.** Nil `wakeState` (a daemon too old
/// to know, or one not yet heard from) and a state with neither flag set are drawn the
/// same way: no row at all. A row that says "not keeping your Mac awake" is a row that
/// trains people to stop reading the footer.
private struct WakefulnessRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let state = model.wakeState, state.hasSomethingToSay {
            // Stacked rather than headline-left/detail-right, which is the shape
            // `SpendingRow` uses below. That shape wrapped: this column is about
            // 226pt wide and "Keeping this Mac awake" plus a trailing count is a few
            // points over, so it broke mid-phrase and read as a mistake. Two lines on
            // purpose, left-aligned, survives a narrower sidebar too.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: state.isHolding ? "sun.max" : "battery.25")
                    .foregroundStyle(state.isHolding ? AnyShapeStyle(.secondary)
                                                     : StateTint.attention.style(or: .secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline(state)).fixedSize(horizontal: false, vertical: true)
                    if let detail = detail(state) {
                        Text(detail).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .appText(.fine)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Paper.sidebar)
            .help(help(state))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(help(state))
        }
    }

    /// The two situations must not read alike. "Nothing is running" and "running, but
    /// your battery is low" are different news, and a person who cannot tell them apart
    /// learns nothing from either (FR-016).
    private func headline(_ state: DaemonAPI.WakeState) -> String {
        state.isHolding ? "Keeping this Mac awake" : "Letting this Mac sleep"
    }

    /// No count of working agents. The daemon tells windows only when the hold is
    /// taken or let go, not as agents join a hold already in place, so a count here
    /// froze at whatever it was when the hold began — "1 working" while three ran.
    /// The sidebar already shows which agents are working; this row says only why
    /// the Mac is awake.
    private func detail(_ state: DaemonAPI.WakeState) -> String? {
        state.isHolding ? nil : state.batteryPercent.map { "\($0)%" }
    }

    private func help(_ state: DaemonAPI.WakeState) -> String {
        if state.isHolding {
            return "This Mac will not sleep while an agent is mid-turn."
        }
        let charge = state.batteryPercent.map { " The battery is at \($0)%." } ?? ""
        return "Work is still in flight, but the battery is low, so this Mac is being "
             + "allowed to sleep." + charge
    }
}
