import AgentsKit
import AppKit
import SwiftUI

/// Settings ▸ Shared (054, look/ frames A–H): what is in `~/.agents` and which runtime
/// gets each thing. Read-only: Edit opens the file in the person's editor and Reveal in
/// Finder opens the folder; the app lays the folder out and reports on it.
///
/// One snapshot from the daemon feeds every page, asked for when the tab appears and
/// whenever the app comes back to the front, which is when an edit made elsewhere shows.
struct SharedSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var snapshot: DaemonAPI.SharedSnapshot?
    @State private var page: SharedPage = .overview

    var body: some View {
        Group {
            if let snapshot {
                if !snapshot.laidOut {
                    SharedOffState()
                } else if snapshot.isEmpty {
                    SharedEmptyState(home: snapshot.home)
                } else {
                    HStack(spacing: 0) {
                        SharedSidebar(snapshot: snapshot, page: $page)
                        Divider()
                        pageView(snapshot)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 1_000, height: 640)
        .background(Paper.ground)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    @ViewBuilder
    private func pageView(_ snapshot: DaemonAPI.SharedSnapshot) -> some View {
        switch page {
        case .overview: SharedOverviewPage(snapshot: snapshot, page: $page)
        case .instructions: SharedInstructionsPage(snapshot: snapshot)
        case .skills: SharedSkillsPage(snapshot: snapshot)
        case .mcp: SharedServersPage(snapshot: snapshot)
        case .plugins: SharedPluginsPage(snapshot: snapshot)
        case .other: SharedOtherFilesPage(snapshot: snapshot)
        }
    }

    private func refresh() async {
        if let fresh = await model.sharedSnapshot() { snapshot = fresh }
    }
}

/// The two colours the tab draws in. What a runtime gets, and the chosen row, are in the
/// accent, as the approved frames have them (look/): not a state, so not a `StateTint`,
/// and the one line ConsistencyTests allows here. Everything that needs a look is
/// `StateTint.attention`.
enum SharedInk {
    static let reach = Color.accentColor
    static var attention: Color { StateTint.attention.color ?? .secondary }
}

enum SharedPage: Hashable {
    case overview, instructions, skills, mcp, plugins, other

    init(_ page: DaemonAPI.Look.Page) {
        switch page {
        case .instructions: self = .instructions
        case .skills: self = .skills
        case .mcp: self = .mcp
        case .plugins: self = .plugins
        case .other: self = .other
        }
    }
}

extension DaemonAPI.SharedSnapshot {
    /// Nothing in the folder yet: frame H.
    var isEmpty: Bool {
        instructions?.exists != true && skills.isEmpty && mcp.servers.isEmpty && mcp.problem == nil
            && plugins.isEmpty && otherFiles.isEmpty
    }

    func warns(_ page: DaemonAPI.Look.Page) -> Bool {
        needsALook.contains { $0.page == page && ($0.kind == .clash || $0.kind == .problem || $0.kind == .leftOut) }
    }
}

// MARK: - Sidebar

private struct SharedSidebar: View {
    let snapshot: DaemonAPI.SharedSnapshot
    @Binding var page: SharedPage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            item("Overview", .overview, count: nil, warns: false)
            Text("In ~/.agents")
                .appText(.fine).textCase(.uppercase).foregroundStyle(.secondary)
                .padding(.top, 14).padding(.bottom, 2).padding(.leading, 10)
            item("Instructions", .instructions, count: snapshot.instructions?.exists == true ? 1 : 0,
                 warns: snapshot.warns(.instructions))
            item("Skills", .skills, count: snapshot.skills.count, warns: snapshot.warns(.skills))
            item("MCP servers", .mcp, count: snapshot.mcp.problem == nil ? snapshot.mcp.servers.count : nil,
                 warns: snapshot.warns(.mcp))
            item("Plugins", .plugins, count: snapshot.plugins.count, warns: snapshot.warns(.plugins))
            item("Other files", .other, count: snapshot.otherFiles.count, warns: false)
            Spacer()
            Text("Your own set, for every project. A project’s own .agents folder is on its project page.")
                .appText(.fine).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
        }
        .padding(12)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(Paper.sidebar)
    }

    private func item(_ title: String, _ target: SharedPage, count: Int?, warns: Bool) -> some View {
        let chosen = page == target
        return Button {
            page = target
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Spacer()
                if warns {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(chosen ? .white : SharedInk.attention)
                }
                if let count { Text("\(count)").monospacedDigit() }
            }
            .foregroundStyle(chosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(chosen ? SharedInk.reach : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + (count.map { ", \($0)" } ?? "") + (warns ? ", needs a look" : ""))
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - The states with nothing to list

/// Frame H: the folder is there and empty.
private struct SharedEmptyState: View {
    let home: String

    var body: some View {
        VStack(spacing: 14) {
            // Decorative: the tab's own symbol, large, above the words that say it all.
            Image(systemName: "square.on.square").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Nothing shared yet").appText(.title)
            Text("Put things in ~/.agents once and every agent gets them, on every runtime: AGENTS.md for instructions · skills/ · mcp.json for MCP servers · plugins/")
                .appText(.supporting).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Reveal ~/.agents in Finder") { SharedFiles.reveal(home) }.buttonStyle(.paper)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A copy of the app with no personal home of its own (research R4).
private struct SharedOffState: View {
    var body: some View {
        VStack(spacing: 10) {
            // Decorative: the tab's own symbol, large, above the words that say it all.
            Image(systemName: "square.on.square").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("The shared folder is off for this copy of the app").appText(.reading)
            Text("It lays out and reports on ~/.agents only for the app’s own daemon, so a copy being tried out leaves your home folder alone.")
                .appText(.fine).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pieces every page uses

enum SharedFiles {
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
    }

    static func open(_ path: String) {
        NSWorkspace.shared.open(URL(filePath: path))
    }

    static func tilde(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

/// A page's title line: its name, the path in code type, and what it offers.
struct SharedPageHeader<Actions: View>: View {
    let title: String
    let path: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).appText(.reading).fontWeight(.semibold)
            Text(SharedFiles.tilde(path)).appText(.code).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            actions
        }
    }
}

struct SharedSectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).appText(.fine).textCase(.uppercase).foregroundStyle(.secondary)
            .padding(.top, 8)
    }
}

/// A small word in a capsule: a transport, a clash, a plugin's name.
struct SharedChip: View {
    enum Tone { case plain, attention, source }

    let text: String
    var tone: Tone = .plain

    var body: some View {
        Text(text)
            .appText(.fine)
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
            .lineLimit(1)
            .fixedSize()
    }

    private var foreground: Color {
        switch tone {
        case .plain: .secondary
        case .attention: SharedInk.attention
        case .source: SharedInk.reach
        }
    }

    private var background: Color {
        switch tone {
        case .plain: Paper.wash
        case .attention: SharedInk.attention.opacity(0.14)
        case .source: SharedInk.reach.opacity(0.12)
        }
    }
}

/// A selectable row in a page's list: the whole row is the button (memory: a tap on a
/// card never fires), raised when chosen.
struct SharedRow<Content: View>: View {
    let chosen: Bool
    let label: String
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Paper.raised, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(chosen ? SharedInk.reach : Paper.rule, lineWidth: chosen ? 2 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }
}

/// A label and its value, as the detail panes list them.
struct SharedFact: View {
    let label: String
    let value: String
    var code = false

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .appText(code ? .code : .reading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What each runtime does with one thing, a line each, in the detail panes.
struct SharedReachList: View {
    let runtimes: [DaemonAPI.RuntimeName]
    let reach: [String: DaemonAPI.Reach]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(runtimes) { runtime in
                if let each = reach[runtime.id] {
                    GridRow(alignment: .firstTextBaseline) {
                        Text(runtime.name).foregroundStyle(.secondary)
                        Text(Self.line(each)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    static func line(_ reach: DaemonAPI.Reach) -> String {
        switch reach {
        case .gets(let note): "✓ \(note)"
        case .ownCopy(let path): "uses its own copy in \(SharedFiles.tilde(path))"
        case .leftOut(let note): "✗ \(note)"
        case .noWay(let note): "✗ \(note)"
        case .unchecked(let note): "? \(note ?? "not checked yet")"
        }
    }
}
