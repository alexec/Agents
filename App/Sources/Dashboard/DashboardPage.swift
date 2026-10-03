import AgentsKitCore
import SwiftUI

/// A project's Dashboard, in the chat's place (FR-031): tiles in sections, in the order
/// they were made, small ones in a grid of 180 pt cells and tables and notes across.
struct DashboardPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let folder: URL

    @State private var showsHidden = false
    @State private var detail: TileView?

    var body: some View {
        let snapshot = model.dashboard(in: folder)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                heading(snapshot)
                if let snapshot {
                    let sections = DashboardModel.sections(snapshot, includeHidden: showsHidden)
                    if sections.isEmpty {
                        empty(hiddenCount: snapshot.tiles.filter { $0.tile?.isHidden == true }.count)
                    }
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        sectionView(section.title, section.tiles, now: snapshot.now)
                    }
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
        .task(id: model.dashboardRevision(in: folder)) { await model.refreshDashboard(folder) }
        .sheet(item: $detail) { tile in
            TileDetail(tile: tile, now: snapshot?.now ?? .now) { detail = nil }.paperSheet()
        }
    }

    private func heading(_ snapshot: DashboardSnapshot?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dashboard").appText(.title).fontWeight(.semibold)
                Text(subtitle(snapshot)).appText(.supporting).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
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

    private func sectionView(_ title: String?, _ tiles: [TileView], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased())
                    .appText(.fine).fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
            }
            ForEach(Array(runs(tiles).enumerated()), id: \.offset) { _, run in
                if run.count == 1, let only = run.first, TileCard.isWide(only) {
                    card(only, now: now)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 360), spacing: 10, alignment: .top)],
                              alignment: .leading, spacing: 10) {
                        ForEach(run) { tile in card(tile, now: now) }
                    }
                }
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
                 openLink: open)
            .contentShape(.rect)
            .onTapGesture(count: 2) { detail = tile }
            .contextMenu { menu(tile) }
            .overlay(alignment: .topTrailing) {
                Menu { menu(tile) } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .padding(8)
                    .help("Hide, remove or open its keeper")
                    .accessibilityLabel("Tile options")
            }
    }

    @ViewBuilder
    private func menu(_ tile: TileView) -> some View {
        Button("Details…") { detail = tile }
        Button("Open Keeper") { model.openKeeper(tile.keeper, folder: folder) }
            .disabled(tile.keeper.id.isEmpty)
        Divider()
        if tile.tile?.isHidden == true {
            Button("Show") { Task { await model.actOnTile(DaemonAPI.Method.dashboardShow, folder: folder, id: tile.id) } }
        } else {
            Button("Hide") { Task { await model.actOnTile(DaemonAPI.Method.dashboardHide, folder: folder, id: tile.id) } }
                .disabled(tile.tile == nil)
        }
        Button("Remove") { Task { await model.actOnTile(DaemonAPI.Method.dashboardRemove, folder: folder, id: tile.id) } }
    }

    private func open(_ link: TileLink) {
        if let url = link.url.flatMap(URL.init(string:)) {
            openURL(url)
        } else if let session = link.session.flatMap(UUID.init(uuidString:)) {
            model.openAgent(session)
        } else if let workflow = link.workflow {
            model.showWorkflow(folder: folder, workflowID: workflow)
        }
    }
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
