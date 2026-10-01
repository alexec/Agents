import AgentsKitCore
import AppKit
import SwiftUI

/// Settings ▸ Shared (054, look/ frames A–H): what is in `~/.agents` and which runtime
/// gets each thing. Read-only: Edit opens the file in the person's editor and Reveal in
/// Finder opens the folder; the app lays the folder out and reports on it.
///
/// Its pages are chosen in the Settings rail (055), which also holds the one snapshot from
/// the daemon that feeds every page, since the rail shows their counts.
struct SharedSettingsView: View {
    let snapshot: DaemonAPI.SharedSnapshot?
    @Binding var page: SharedPage
    /// Read the snapshot again, after something was added from a catalogue (059).
    var refresh: () async -> Void = {}

    var body: some View {
        Group {
            if let snapshot {
                if !snapshot.laidOut {
                    SharedOffState()
                } else if snapshot.isEmpty {
                    SharedEmptyState(home: snapshot.home)
                } else {
                    pageView(snapshot)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func pageView(_ snapshot: DaemonAPI.SharedSnapshot) -> some View {
        switch page {
        case .overview: SharedOverviewPage(snapshot: snapshot, page: $page)
        case .instructions: AgentsSetupPage { AgentsInstructionsSection(place: .you) }.task { await refresh() }
        case .skills: AgentsSetupPage { AgentsSkillsSection(place: .you) }.task { await refresh() }
        case .mcp: AgentsSetupPage { ProjectMCPSection(place: .you) }.task { await refresh() }
        case .plugins: AgentsSetupPage { AgentsPluginsSection(place: .you) }.task { await refresh() }
        case .other: SharedOtherFilesPage(snapshot: snapshot)
        }
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

enum SharedPage: String, Hashable {
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
    /// Nothing in the folder yet: frame H. The instructions do not count: the layout
    /// writes a starter `AGENTS.md` into every folder it makes, so it is always there.
    var isEmpty: Bool {
        skills.isEmpty && mcp.servers.isEmpty && mcp.problem == nil && plugins.isEmpty && otherFiles.isEmpty
    }

    func warns(_ page: DaemonAPI.Look.Page) -> Bool {
        needsALook.contains { $0.page == page && ($0.kind == .clash || $0.kind == .problem || $0.kind == .leftOut) }
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
    /// In the App Store window, what this Mac's host does for these (058, US1): set by the
    /// model when it starts. Your ~/.agents and a project's files are on this Mac.
    @MainActor static var onThisMacsHost: ((URL, _ reveal: Bool) -> Void)?

    @MainActor static func reveal(_ path: String) {
        onThisMacsHost?(URL(filePath: path), true)
    }

    @MainActor static func open(_ path: String) {
        onThisMacsHost?(URL(filePath: path), false)
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
                .paperRaised(in: RoundedRectangle(cornerRadius: Paper.Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Paper.Radius.control)
                    .strokeBorder(chosen ? SharedInk.reach : .clear, lineWidth: chosen ? 2 : 0))
                .contentShape(RoundedRectangle(cornerRadius: Paper.Radius.control))
        }
        .buttonStyle(.plain)
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
