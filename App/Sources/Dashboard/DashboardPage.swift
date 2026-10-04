import AgentsKitCore
import SwiftUI

/// A project's Dashboard, in the chat's place (FR-031): tiles in sections, small ones in a
/// grid of 180 pt cells and tables and notes across, in the order a person or an agent
/// put them (#147), or else the order they were made. Tiles drag within and between
/// sections, and a section drags by its heading; their menus move them without a pointer.
struct DashboardPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let folder: URL
    /// The project's host: what its Dashboard is asked of, whatever is selected by then.
    let host: HostID

    @State private var showsHidden = false
    @State private var detail: TileView?

    var body: some View {
        let snapshot = model.dashboard(in: folder)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                heading(snapshot)
                // A file of this Dashboard's set aside as unreadable (#171).
                if let note = snapshot?.note {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let snapshot {
                    let sections = DashboardModel.sections(snapshot, includeHidden: showsHidden)
                    if sections.isEmpty {
                        empty(hiddenCount: snapshot.tiles.filter { $0.tile?.isHidden == true }.count)
                    }
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(Array(sections.enumerated()), id: \.element.title) { index, section in
                            sectionView(section.title, section.tiles, now: snapshot.now,
                                        place: (index, sections.count, sections.map(\.title)))
                        }
                    }
                    // One container for every section's grids, so a tile drags from one
                    // section into another; a drop is sent once, as the whole order.
                    .reorderContainer(for: TileView.self, in: TileRun.self) { difference in
                        apply(difference)
                    }
                    // The tiles are the project's files (#127).
                    Text(DashboardModel.filesSentence + ".")
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        // The project's own page now a project's row opens it (#145): named for the
        // project, as a chat is named for its session.
        .navigationTitle(AppCheckout.windowTitle(model.selectedProjectSummary?.name))
        .navigationSubtitle("Dashboard")
        .task(id: model.dashboardRevision(in: folder)) { await model.refreshDashboard(folder, on: host) }
        .sheet(item: $detail) { tile in
            TileDetail(tile: tile, now: snapshot?.now ?? .now) { detail = nil }.paperSheet()
        }
    }

    private func heading(_ snapshot: DashboardSnapshot?) -> some View {
        // Ticks so the cooldown's end re-enables the button without a change from the host.
        TimelineView(.periodic(from: .now, by: 15)) { context in
            headingRow(snapshot, now: context.date)
        }
    }

    private func headingRow(_ snapshot: DashboardSnapshot?, now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dashboard").appText(.title).fontWeight(.semibold)
                Text(subtitle(snapshot)).appText(.supporting).foregroundStyle(.secondary)
                if let update = snapshot?.update { updateLine(update, now: now) }
            }
            Spacer(minLength: 0)
            if let update = snapshot?.update { updateButton(update, now: now) }
            Menu {
                Toggle("Show Hidden Tiles", isOn: $showsHidden)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Show Hidden Tiles")
            .accessibilityLabel("Dashboard options")
        }
    }

    /// Update now (#146): Updating… while a run is going, off while it can't start.
    private func updateButton(_ update: DashboardUpdate, now: Date) -> some View {
        Button {
            Task { await model.updateDashboard(folder, on: host) }
        } label: {
            if update.isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Updating…")
                }
            } else {
                Label("Update now", systemImage: "arrow.clockwise")
            }
        }
        .disabled(!update.canPress(now: now))
        .help(update.workflowID == nil
              ? "Start an agent to set every tile again from its source"
              : "Run \u{201C}\(update.name)\u{201D} now, as Run now would")
    }

    /// What is going, why it can't, or how the last one went, with the way to its session.
    @ViewBuilder
    private func updateLine(_ update: DashboardUpdate, now: Date) -> some View {
        if let line = update.line(now: now) {
            HStack(spacing: 6) {
                Text(line)
                    .foregroundStyle(update.lastFailed && !update.isRunning ? AnyShapeStyle(StateTint.failure.style(or: .secondary))
                                                                             : AnyShapeStyle(.secondary))
                if update.blocked != nil, let workflow = update.workflowID {
                    Button("Open Workflow") { model.showWorkflow(folder: folder, workflowID: workflow) }
                        .buttonStyle(.link)
                } else if let agent = update.agentID, update.isRunning || update.lastFailed {
                    Button("Open Session") { model.openAgent(agent) }
                        .buttonStyle(.link)
                }
            }
            .appText(.fine)
        }
    }

    private func subtitle(_ snapshot: DashboardSnapshot?) -> String {
        let name = model.selectedProjectSummary?.name ?? folder.lastPathComponent
        guard let snapshot, let newest = snapshot.tiles.compactMap(\.setAt).max() else {
            return "\(name) · kept by its agents"
        }
        let probe = TileView(id: "", tile: TileFile(title: "", type: .note, keeper: TileKeeper(), staleAfterHours: 168),
                             setAt: newest, keeper: KeeperView(kind: .agent, id: "", name: "", state: .active))
        return "\(name) · updated \(DashboardModel.ageWords(probe, now: snapshot.now))"
    }

    private func empty(hiddenCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hiddenCount > 0 ? "Every tile is hidden." : "No tiles yet.")
                .appText(.reading)
            Text(hiddenCount > 0
                 ? "Show Hidden Tiles, in the menu above, brings them back."
                 : "Agents keep tiles here with set_tile: a number with its trend, a status, a table, a note or a link. Ask one to keep what you check often.")
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 12)
    }

    private func sectionView(_ title: String?, _ tiles: [TileView], now: Date,
                             place: (index: Int, count: Int, titles: [String?])) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased())
                    .appText(.fine).fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    // A section moves by its heading: dragged onto another heading it goes
                    // before that section (#147).
                    .draggable(Self.sectionDragPrefix + title)
                    .dropDestination(for: String.self) { items, _ in
                        guard let dragged = items.first, dragged.hasPrefix(Self.sectionDragPrefix) else { return false }
                        let moving = String(dragged.dropFirst(Self.sectionDragPrefix.count))
                        guard moving != title else { return false }
                        arrange { $0.movingSection(moving, before: .some(title)) }
                        return true
                    }
                    .contextMenu {
                        Button("Move Section Up") {
                            arrange { $0.movingSection(title, before: .some(place.titles[place.index - 1])) }
                        }
                        .disabled(place.index == 0)
                        Button("Move Section Down") {
                            let after = place.index + 2
                            arrange { $0.movingSection(title, before: after < place.count ? .some(place.titles[after]) : nil) }
                        }
                        .disabled(place.index + 1 >= place.count)
                    }
            }
            ForEach(Array(runs(tiles).enumerated()), id: \.offset) { index, run in
                let id = TileRun(section: title, index: index)
                if run.count == 1, let only = run.first, TileCard.isWide(only) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(run) { tile in card(tile, now: now) }
                            .reorderable(collectionID: id)
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 360), spacing: 10, alignment: .top)],
                              alignment: .leading, spacing: 10) {
                        ForEach(run) { tile in card(tile, now: now) }
                            .reorderable(collectionID: id)
                    }
                }
            }
        }
    }

    private static let sectionDragPrefix = "agents-dashboard-section:"

    /// The order as shown, changed by `change`, kept at once and sent once.
    private func arrange(_ change: (DashboardOrder) -> DashboardOrder?) {
        guard let snapshot = model.dashboard(in: folder),
              let order = change(DashboardModel.arrangement(snapshot)) else { return }
        Task { await model.arrangeDashboard(order, folder: folder, on: host) }
    }

    /// A drop: the tiles go before the one they were dropped on, or after the last of the
    /// grid they were dropped at the end of.
    private func apply(_ difference: ReorderDifference<TileView.ID, TileRun>) {
        let target = difference.destination.collectionID
        let sources = difference.sources
        switch difference.destination.position {
        case .before(let id):
            arrange { $0.moving(sources, to: target.section, before: id) }
        case .end:
            guard let snapshot = model.dashboard(in: folder) else { return }
            let shown = DashboardModel.sections(snapshot, includeHidden: showsHidden)
            let run = shown.first { $0.title == target.section }.map { runs($0.tiles) } ?? []
            let rest = run.indices.contains(target.index) ? run[target.index].map(\.id).filter { !sources.contains($0) } : []
            if let last = rest.last {
                arrange { $0.moving(sources, after: last) }
            } else {
                arrange { $0.moving(sources, to: target.section) }
            }
        }
    }

    /// Small tiles grouped into grids, each wide one on its own, in order.
    private func runs(_ tiles: [TileView]) -> [[TileView]] {
        var out: [[TileView]] = []
        for tile in tiles {
            if TileCard.isWide(tile) {
                out.append([tile])
            } else if let last = out.last, let first = last.first, !TileCard.isWide(first) {
                out[out.count - 1].append(tile)
            } else {
                out.append([tile])
            }
        }
        return out
    }

    private func card(_ tile: TileView, now: Date) -> some View {
        TileCard(tile: tile, now: now,
                 openKeeper: { model.openKeeper(tile.keeper, folder: folder) },
                 openLink: open,
                 page: { page in AnyView(PageTileBody(project: project, file: page.file)) })
            .contentShape(.rect)
            .onTapGesture(count: 2) { detail = tile }
            .contextMenu { menu(tile) }
            .overlay(alignment: .topTrailing) {
                Menu { menu(tile) } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(8)
                    .help("Move, hide, remove or open its keeper")
                    .accessibilityLabel("Tile options")
            }
    }

    @ViewBuilder
    private func menu(_ tile: TileView) -> some View {
        Button("Details…") { detail = tile }
        Button("Open Keeper") { model.openKeeper(tile.keeper, folder: folder) }
            .disabled(tile.keeper.id.isEmpty)
        moveItems(tile)
        Divider()
        if tile.tile?.isHidden == true {
            Button("Show") { Task { await model.actOnTile(DaemonAPI.Method.dashboardShow, folder: folder, on: host, id: tile.id) } }
        } else {
            Button("Hide") { Task { await model.actOnTile(DaemonAPI.Method.dashboardHide, folder: folder, on: host, id: tile.id) } }
                .disabled(tile.tile == nil)
        }
        Button("Remove") { Task { await model.actOnTile(DaemonAPI.Method.dashboardRemove, folder: folder, on: host, id: tile.id) } }
    }

    /// Move Up, Move Down and Move to Section ▸: the order without a drag (#147).
    @ViewBuilder
    private func moveItems(_ tile: TileView) -> some View {
        if let snapshot = model.dashboard(in: folder) {
            let shown = DashboardModel.sections(snapshot, includeHidden: showsHidden)
            let current = shown.first { $0.tiles.contains { $0.id == tile.id } }?.title
            Divider()
            Button("Move Up") {
                arrange { _ in DashboardModel.stepping(tile.id, by: -1, in: snapshot, includeHidden: showsHidden) }
            }
            .disabled(DashboardModel.neighbour(of: tile.id, in: shown, step: -1) == nil)
            Button("Move Down") {
                arrange { _ in DashboardModel.stepping(tile.id, by: 1, in: snapshot, includeHidden: showsHidden) }
            }
            .disabled(DashboardModel.neighbour(of: tile.id, in: shown, step: 1) == nil)
            let others = shown.map(\.title).filter { $0 != current }
            if !others.isEmpty {
                Menu("Move to Section") {
                    ForEach(Array(others.enumerated()), id: \.offset) { _, title in
                        Button(title ?? "No Section") { arrange { $0.moving([tile.id], to: title) } }
                    }
                }
            }
        }
    }

    private func open(_ link: TileLink) {
        if let url = link.url.flatMap(URL.init(string:)) {
            openURL(url)
        } else if let session = link.session.flatMap(UUID.init(uuidString:)) {
            model.openAgent(session)
        } else if let workflow = link.workflow {
            model.showWorkflow(folder: folder, workflowID: workflow)
        } else if let file = link.file.flatMap(PinRules.normalize), PinRules.kind(file) != nil {
            // A document or a page of the project's opens where a pinned one does (#159).
            model.showPin(file, in: project)
        }
    }

    private var project: ProjectKey { ProjectKey(host: model.selectedProjectHost, folder: folder) }
}

/// One grid of a section's tiles (#147): a section's small tiles run together in a grid
/// and each wide one stands alone, so a drop lands in a section and a place in it.
struct TileRun: Hashable, Sendable {
    var section: String?
    var index: Int
}

/// A tile's detail (FR-035): its source, keeper and keeper changes, whether it was
/// changed outside Agents, and its last ten values.
struct TileDetail: View {
    let tile: TileView
    let now: Date
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tile.tile?.title ?? tile.id).appText(.title).fontWeight(.semibold)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                row("File", ".agents/dashboard/\(tile.id).json")
                if tile.tile?.type == .number { row("History", DashboardModel.historyFile(tile.id)) }
                row("Kept by", "\(tile.keeper.name) (\(tile.keeper.kind.rawValue))"
                    + (DashboardModel.keeperNote(tile.keeper).map { ", \($0)" } ?? ""))
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
                    }
                    .appText(.supporting)
                }
            }
            HStack {
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).appText(.fine).foregroundStyle(.secondary)
            Text(value).appText(.supporting).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
