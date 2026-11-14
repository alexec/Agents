#if os(macOS)
import AgentsKitCore
import SwiftUI

/// Work ▸ Deploys's state (#5270), kept by the model while the app runs, so Back from a
/// release's page finds the page as it was left.
@MainActor
@Observable
final class WorkDeploysState {
    var targets: [DaemonAPI.DeployTargetNow]?
    var problem: String?
    var reading = false
    var asked = 0
    /// When what is on screen was read (#5139): this device's copy's time, or the last read.
    var read: Date?
    /// What is on screen came from this device's copy (#4930), until the machines answer.
    var fromDevice = false

    private static let kept = "all"

    func load(model: any WorkModel) async {
        let mine = asked
        reading = true
        defer { if asked == mine { reading = false } }
        if targets == nil, case let (copy, at)? = await model.keptWorkRead([DaemonAPI.DeployTargetNow].self, .deploys, Self.kept),
           asked == mine, targets == nil {
            targets = copy
            read = at
            fromDevice = true
        }
        let machines = model.deploysMachines
        var got: [(Int, [DaemonAPI.DeployTargetNow])] = []
        var failed: [String] = []
        await withTaskGroup(of: (Int, [DaemonAPI.DeployTargetNow]?, String?).self) { group in
            for (i, machine) in machines.enumerated() {
                group.addTask {
                    do {
                        let t = try await model.forge(DaemonAPI.Method.deploysTargets, DaemonAPI.DeployTargetsRequest(),
                                                      returning: DaemonAPI.DeployTargets.self, on: machine.id)
                        return (i, t.targets, nil)
                    } catch {
                        return (i, nil, machines.count > 1 ? "\(machine.name): \(error.localizedDescription)" : error.localizedDescription)
                    }
                }
            }
            for await (i, t, problem) in group {
                if let t { got.append((i, t)) }
                if let problem { failed.append(problem) }
            }
        }
        guard asked == mine else { return }
        problem = failed.isEmpty ? nil : failed.joined(separator: "\n")
        // Every machine failed: what is on screen stays, with its time in the strip.
        if got.isEmpty, !failed.isEmpty { return }
        let merged = WorkDeploys.merge(got.sorted { $0.0 < $1.0 }.map(\.1))
        targets = merged
        read = .now
        fromDevice = false
        if failed.isEmpty { model.keepWork(merged, .deploys, Self.kept) }
    }
}

/// Work ▸ Deploys (#5270, spec 5239-deploy-model board 4): the environments across in tier
/// order, the components down, each cell a target with its live versions, since when, and what
/// goes next. A click on a cell opens the deploy's job; on a version, its release's page.
struct WorkDeploysPane: View {
    let model: any WorkModel
    @Bindable var state: WorkDeploysState
    @Environment(\.openURL) private var openURL

    static let column: CGFloat = 190
    static let nameColumn: CGFloat = 130

    var body: some View {
        VStack(spacing: 0) {
            WorkFromDeviceStrip(read: state.fromDevice ? state.read : nil)
            if let problem = state.problem {
                WorkErrorStrip(lines: problem.components(separatedBy: "\n"), read: state.read) { state.asked += 1 }
            }
            content
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                WorkRefreshButton(running: state.reading) { state.asked += 1 }
            }
        }
        .workTask(id: state.asked) { await state.load(model: model) }
        // Read again every minute, so a deploy that lands shows while the page is open.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                state.asked += 1
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.deploysMachines.isEmpty {
            WorkEmptyState(symbol: WorkList.Kind.deploy.sidebarIcon, title: "No machine keeps deploys",
                           line: WorkDeploys.noMachine)
        } else if let targets = state.targets {
            let grid = WorkDeploys.grid(targets)
            if grid.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    header.padding(.horizontal, 24)
                    WorkEmptyState(symbol: WorkList.Kind.deploy.sidebarIcon, title: WorkDeploys.emptyTitle,
                                   line: WorkDeploys.emptyLine)
                }
            } else {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        table(grid)
                        Text("A click on a cell opens the deploy’s job; on a version, its release’s page.")
                            .appText(.fine)
                            .foregroundStyle(Paper.tertiary)
                            .padding(.top, 14)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.horizontal, 24)
                // A read that failed with nothing read before: the strip alone, no placeholders.
                if state.problem == nil { WorkPlaceholderRows().padding(.horizontal, 24) }
                Spacer(minLength: 0)
            }
        }
    }

    /// The page's title and, once read, "Last update 72 min ago" (#5139).
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(WorkDeploys.title).appText(.title).fontWeight(.bold)
            if let read = state.read { LastUpdateText(read: read) }
        }
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func table(_ grid: WorkDeploys.Grid) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 0) {
            GridRow {
                Color.clear.frame(width: Self.nameColumn, height: 1)
                ForEach(grid.columns) { col in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(col.name).appText(.supporting).fontWeight(.semibold).lineLimit(1)
                        if let chip = WorkDeploys.tierChip(col.tier) {
                            WorkReleaseChip(words: chip, color: WorkLook.Tone.purple.color)
                        }
                    }
                    .frame(width: Self.column, alignment: .leading)
                    .padding(.bottom, 10)
                    .accessibilityAddTraits(.isHeader)
                }
            }
            ForEach(grid.rows) { row in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text(row.name)
                        .appText(.reading)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .frame(width: Self.nameColumn, alignment: .leading)
                        .padding(.top, 14)
                    ForEach(Array(grid.columns.enumerated()), id: \.element.id) { i, col in
                        cell(row.cells[i])
                            .padding(.vertical, 8)
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(WorkDeploys.cellLabel(component: row.name, environment: col.name, row.cells[i]))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ targets: [DaemonAPI.DeployTargetNow]) -> some View {
        if targets.isEmpty {
            Text(WorkDeploys.none)
                .appText(.reading)
                .foregroundStyle(Paper.tertiary)
                .frame(width: Self.column, alignment: .leading)
                .padding(.top, 6)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(targets, id: \.self) { WorkDeployCard(model: model, target: $0, openURL: openURL) }
            }
            .frame(width: Self.column, alignment: .leading)
        }
    }
}

/// One target in a cell: its labels, each live version (with its share when the traffic is
/// split) and since when, and each next deploy. The card opens the newest deploy's job.
private struct WorkDeployCard: View {
    let model: any WorkModel
    let target: DaemonAPI.DeployTargetNow
    let openURL: OpenURLAction
    @State private var hover = false

    private var job: URL? {
        (target.next.last?.deploy.url ?? target.live.first?.deploy.url).flatMap(URL.init(string:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let labels = WorkDeploys.labelsLine(target.target)
            if !labels.isEmpty {
                Text(labels).appText(.fine).foregroundStyle(Paper.tertiary).lineLimit(1)
            }
            if target.live.isEmpty {
                Text(WorkDeploys.noLive).appText(.supporting).foregroundStyle(Paper.tertiary)
            }
            ForEach(target.live, id: \.self) { live in
                HStack(spacing: 6) {
                    version(live)
                    Spacer(minLength: 4)
                    if live.deploy.rollback == true {
                        WorkReleaseChip(words: WorkDeploys.rollback, color: Paper.forgeWaiting)
                    } else if live == target.live.first {
                        WorkReleaseChip(words: WorkDeploys.live, color: WorkLook.Tone.green.color)
                    }
                }
                if let share = WorkDeploys.shareWords(live.share) {
                    HStack(spacing: 6) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Paper.wash)
                                Capsule().fill(WorkLook.Tone.green.color).frame(width: g.size.width * (live.share ?? 100) / 100)
                            }
                        }
                        .frame(height: 5)
                        Text(share).appText(.fine).foregroundStyle(Paper.secondary).monospacedDigit()
                    }
                }
                if let since = live.since {
                    Text(WorkDeploys.sinceWords(since)).appText(.fine).foregroundStyle(Paper.secondary)
                }
            }
            ForEach(target.next, id: \.self) { next in
                Text(WorkDeploys.nextWords(next)).appText(.fine).foregroundStyle(Paper.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Paper.Radius.card).fill(hover && job != nil ? Paper.well : Paper.raised))
        .overlay(RoundedRectangle(cornerRadius: Paper.Radius.card).strokeBorder(Paper.rule))
        .contentShape(RoundedRectangle(cornerRadius: Paper.Radius.card))
        .onHover { hover = $0 }
        .onTapGesture { if let job { openURL(job) } }
        .help(job == nil ? "" : "Open the deploy’s job")
        .accessibilityAction(named: "Open the deploy’s job") { if let job { openURL(job) } }
    }

    /// The version's name; a release's opens its page.
    @ViewBuilder
    private func version(_ live: DaemonAPI.DeployOnTarget) -> some View {
        let words = WorkDeploys.versionWords(live.deploy.version)
        if let release = live.release {
            Button(words) { model.showWork(WorkPlace(kind: .release, ref: release)) }
                .buttonStyle(.plain)
                .appText(.reading)
                .fontWeight(.semibold)
                .help("Open the release’s page")
        } else {
            Text(words).appText(.reading).fontWeight(.semibold).lineLimit(1)
        }
    }
}
#endif
