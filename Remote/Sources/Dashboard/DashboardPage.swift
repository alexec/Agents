import AgentsKitCore
import SwiftUI

/// The Dashboard row on the project page (074 FR-032): above Sessions, with a one-line
/// summary — the worst live status and the first number — worth a glance unopened.
struct DashboardRow: View {
    @Environment(RemoteModel.self) private var model
    let folder: URL

    var body: some View {
        let summary = model.work.dashboardSummary(in: folder)
        NavigationLink(value: RemoteRoute.dashboard) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "square.grid.2x2")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dashboard").appText(.reading).fontWeight(.semibold)
                    HStack(spacing: 6) {
                        if (summary?.bad ?? 0) > 0 {
                            Circle().fill(StateTint.failure.style(or: .secondary)).frame(width: 7, height: 7)
                        }
                        Text(Self.detail(summary))
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").appText(.fine).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(Paper.raised, in: .rect(cornerRadius: Paper.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Paper.Radius.card).strokeBorder(Paper.rule))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .task(id: folder) { await model.refreshDashboardSummaryIfNeeded(in: folder) }
    }

    static func detail(_ summary: DashboardSummary?) -> String {
        guard let summary, summary.tiles > 0 else { return "No tiles yet" }
        return summary.line.isEmpty ? (summary.tiles == 1 ? "1 tile" : "\(summary.tiles) tiles") : summary.line
    }
}

/// The tiles in one column (FR-032): numbers two across, tables to their first five rows
/// with a way to see them all, and a long press for Move, Hide, Remove and Open Keeper.
/// The long press is the menu, so tiles move by its Move Up, Move Down and Move to
/// Section rather than a drag (#147, which replaced Alex's decision 7).
struct DashboardPage: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var wholeTable: TileView?
    @State private var detail: TileView?
    @State private var showsHidden = false

    private var folder: URL? { model.selectedProject }

    var body: some View {
        let snapshot = folder.flatMap { model.work.dashboards[Project.standardize($0)] }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let snapshot {
                    if let update = snapshot.update { updateLine(update) }
                    Text(subtitle(snapshot)).appText(.fine).foregroundStyle(.secondary)
                    Toggle("Show Hidden Tiles", isOn: $showsHidden)
                        .appText(.fine)
                    // A file of this Dashboard's set aside as unreadable (#171).
                    if let note = snapshot.note {
                        Label(note, systemImage: "exclamationmark.triangle")
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                    }
                    let sections = DashboardModel.sections(snapshot, includeHidden: showsHidden)
                    if sections.isEmpty {
                        Text(snapshot.tiles.contains(where: { $0.tile?.isHidden == true })
                             ? "Every tile is hidden. Turn on Show Hidden Tiles above to bring them back."
                             : "No tiles yet. Agents keep tiles here with set_tile.")
                            .appText(.reading).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        if let title = section.title {
                            Text(title.uppercased())
                                .appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                                .padding(.top, 10)
                                .contextMenu { sectionMoves(title, sections: sections, snapshot: snapshot) }
                        }
                        ForEach(Array(rows(section.tiles).enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .top, spacing: 10) {
                                ForEach(row) { tile in card(tile, now: snapshot.now) }
                            }
                        }
                    }
                    // The tiles are the project's files (#127), the Mac page's words.
                    Text(DashboardModel.filesSentence + ".")
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .readableWidth()
        }
        .navigationTitle("Dashboard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let update = snapshot?.update, let folder {
                ToolbarItem(placement: .primaryAction) {
                    // Ticks so the cooldown's end turns the button back on.
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        Button {
                            Task { await model.updateDashboard(folder) }
                        } label: {
                            if update.isRunning {
                                ProgressView()
                            } else {
                                Label("Update now", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(!update.canPress(now: context.date))
                        .accessibilityLabel(update.isRunning ? "Updating…" : "Update now")
                    }
                }
            }
        }
        .task(id: model.work.dashboardRevision(in: folder)) {
            if let folder { await model.refreshDashboard(folder) }
        }
        .onDisappear { model.work.forgetDashboard(in: folder) }
        .refreshable { if let folder { await model.refreshDashboard(folder) } }
        .sheet(item: $wholeTable) { tile in
            NavigationStack {
                ScrollView {
                    TileCard(tile: tile, now: .now).padding(16)
                }
                .navigationTitle(tile.tile?.title ?? tile.id)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { wholeTable = nil } }
            }
            .paperSheet()
        }
        .sheet(item: $detail) { tile in
            NavigationStack {
                ScrollView { RemoteTileDetail(tile: tile, now: snapshot?.now ?? .now) }
                    .navigationTitle(tile.tile?.title ?? tile.id)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { detail = nil } }
            }
            .paperSheet()
        }
    }

    private func subtitle(_ snapshot: DashboardSnapshot) -> String {
        let name = model.selectedProject?.lastPathComponent ?? "Project"
        guard let newest = snapshot.tiles.compactMap(\.setAt).max() else { return "\(name) · kept by its agents" }
        let probe = TileView(id: "", tile: TileFile(title: "", type: .note, keeper: TileKeeper(), staleAfterHours: 168),
                             setAt: newest, keeper: KeeperView(kind: .agent, id: "", name: "", state: .active))
        return "\(name) · updated \(DashboardModel.ageWords(probe, now: snapshot.now))"
    }

    /// Update now's line (#146): what is going, why it can't, how the last one went.
    @ViewBuilder
    private func updateLine(_ update: DashboardUpdate) -> some View {
        if let line = update.line(now: .now) {
            HStack(spacing: 6) {
                if update.isRunning { ProgressView().controlSize(.small) }
                Text(line)
                    .foregroundStyle(update.lastFailed && !update.isRunning ? AnyShapeStyle(StateTint.failure.style(or: .secondary))
                                                                             : AnyShapeStyle(.secondary))
                if update.blocked != nil, let workflow = update.workflowID, let folder {
                    Button("Open Workflow") { model.openWorkflow = Project.standardize(folder).path + "/" + workflow }
                } else if let agent = update.agentID, update.isRunning || update.lastFailed {
                    Button("Open Session") { model.selection = agent }
                }
            }
            .appText(.fine)
            .padding(.top, 4)
        }
    }

    /// Number tiles two across; everything else on a line of its own.
    private func rows(_ tiles: [TileView]) -> [[TileView]] {
        var out: [[TileView]] = []
        for tile in tiles {
            if tile.tile?.type == .number, let last = out.last, last.count == 1, last[0].tile?.type == .number {
                out[out.count - 1].append(tile)
            } else {
                out.append([tile])
            }
        }
        return out
    }

    private func card(_ tile: TileView, now: Date) -> some View {
        TileCard(tile: tile, now: now, rowLimit: 5,
                 openKeeper: { if let folder { model.openKeeper(tile.keeper, folder: folder) } },
                 openLink: open,
                 page: { page in AnyView(folder.map { PageTileBody(folder: $0, file: page.file) }) })
            .contentShape(.rect)
            .onTapGesture {
                if let rows = tile.tile?.table?.rows.count, rows > 5 { wholeTable = tile }
            }
            .onTapGesture(count: 2) { detail = tile }
            .contextMenu {
                if let folder {
                    Button("Details…", systemImage: "info.circle") { detail = tile }
                    Button("Open Keeper", systemImage: "arrow.right") { model.openKeeper(tile.keeper, folder: folder) }
                        .disabled(tile.keeper.id.isEmpty)
                    moveItems(tile, folder: folder)
                    if tile.tile?.isHidden == true {
                        Button("Show", systemImage: "eye") {
                            Task { await model.actOnTile(DaemonAPI.Method.dashboardShow, folder: folder, id: tile.id) }
                        }
                    } else {
                        Button("Hide", systemImage: "eye.slash") {
                            Task { await model.actOnTile(DaemonAPI.Method.dashboardHide, folder: folder, id: tile.id) }
                        }.disabled(tile.tile == nil)
                    }
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        Task { await model.actOnTile(DaemonAPI.Method.dashboardRemove, folder: folder, id: tile.id) }
                    }
                }
            }
    }

    @ViewBuilder
    private func sectionMoves(_ title: String, sections: [(title: String?, tiles: [TileView])], snapshot: DashboardSnapshot) -> some View {
        let index = sections.firstIndex { $0.title == title }
        let order = DashboardModel.arrangement(snapshot)
        if let index {
            Button("Move Section Up", systemImage: "arrow.up") {
                guard index > 0 else { return }
                let before = sections[index - 1].title
                Task { await model.arrangeDashboard(order.movingSection(title, before: .some(before)), folder: snapshot.folder) }
            }.disabled(index == 0)
            Button("Move Section Down", systemImage: "arrow.down") {
                guard index + 1 < sections.count else { return }
                let before = sections[index + 1].title
                Task { await model.arrangeDashboard(order.movingSection(title, before: .some(before)), folder: snapshot.folder) }
            }.disabled(index + 1 >= sections.count)
        }
    }

    /// Move Up, Move Down and Move to Section ▸, as the Mac's tile menu has them (#147).
    @ViewBuilder
    private func moveItems(_ tile: TileView, folder: URL) -> some View {
        if let snapshot = model.work.dashboards[Project.standardize(folder)] {
            let shown = DashboardModel.sections(snapshot, includeHidden: showsHidden)
            let current = shown.first { $0.tiles.contains { $0.id == tile.id } }?.title
            Button("Move Up", systemImage: "arrow.up") {
                arrange(DashboardModel.stepping(tile.id, by: -1, in: snapshot, includeHidden: showsHidden), folder: folder)
            }
            .disabled(DashboardModel.neighbour(of: tile.id, in: shown, step: -1) == nil)
            Button("Move Down", systemImage: "arrow.down") {
                arrange(DashboardModel.stepping(tile.id, by: 1, in: snapshot, includeHidden: showsHidden), folder: folder)
            }
            .disabled(DashboardModel.neighbour(of: tile.id, in: shown, step: 1) == nil)
            let others = shown.map(\.title).filter { $0 != current }
            if !others.isEmpty {
                Menu("Move to Section", systemImage: "folder") {
                    ForEach(Array(others.enumerated()), id: \.offset) { _, title in
                        Button(title ?? "No Section") {
                            arrange(DashboardModel.arrangement(snapshot).moving([tile.id], to: title), folder: folder)
                        }
                    }
                }
            }
        }
    }

    private func arrange(_ order: DashboardOrder?, folder: URL) {
        guard let order else { return }
        Task { await model.arrangeDashboard(order, folder: folder) }
    }

    private func open(_ link: TileLink) {
        if let url = link.url.flatMap(URL.init(string:)) {
            openURL(url)
        } else if let session = link.session.flatMap(UUID.init(uuidString:)) {
            model.selection = session
        } else if let workflow = link.workflow, let folder {
            model.openWorkflow = Project.standardize(folder).path + "/" + workflow
        } else if let file = link.file.flatMap(PinRules.normalize), PinRules.kind(file) != nil {
            // A document or a page of the project's opens where a pinned one does (#159).
            model.openPin = file
        }
    }
}

/// Remote counterpart to the Mac's Dashboard tile detail (#127).
private struct RemoteTileDetail: View {
    let tile: TileView
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                row("File", ".agents/dashboard/\(tile.id).json")
                if tile.tile?.type == .number { row("History", DashboardModel.historyFile(tile.id)) }
                row("Kept by", "\(tile.keeper.name) (\(tile.keeper.kind.rawValue))" +
                    (DashboardModel.keeperNote(tile.keeper).map { ", \($0)" } ?? ""))
                row("Set", DashboardModel.ageWords(tile, now: now))
                if let source = tile.tile?.source { row("Source", source) }
                if let hours = tile.tile?.staleAfterHours { row("Greyed after", "\(hours) h without a set") }
                if tile.changedOutside { row("Changed", "outside Agents: the file is not what this host last wrote") }
                if let problem = tile.problem { row("Problem", problem) }
                ForEach(Array(tile.keeperChanges.enumerated()), id: \.offset) { _, change in
                    row("Handed over", "\(change.from) → \(change.to), \(change.at.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            if !tile.recent.isEmpty {
                Text("Last values").appText(.supporting).fontWeight(.semibold)
                ForEach(Array(tile.recent.reversed().enumerated()), id: \.offset) { _, point in
                    HStack {
                        Text(DashboardModel.numberWords(point.value)).monospacedDigit()
                        Spacer()
                        Text(point.at.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                    }.appText(.supporting)
                }
            }
        }
        .padding(24)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).appText(.fine).foregroundStyle(.secondary)
            Text(value).appText(.supporting).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
