import AgentsKitCore
import AppKit
import SwiftUI

/// Agent Configuration (054, #754): what is in a set of agent files and, for yours, which
/// runtime gets each thing. The same pages in Settings, for `~/.agents`, and in Folder
/// Settings, for a folder's `.agents`. Read-only but for what each section adds: Edit
/// opens the file in the person's editor and Reveal in Finder opens the folder.
///
/// Its pages are chosen in a list inside the pane, with their counts (#1076). The window
/// holds the one snapshot from the daemon that feeds every page.
struct AgentConfigurationView: View {
    @Environment(AppModel.self) private var model
    let place: AgentsPlace
    let snapshot: DaemonAPI.SharedSnapshot?
    @Binding var page: AgentConfigurationPage
    /// Pages with something waiting for the person's OK, such as a folder's new plugin.
    var waiting: Set<AgentConfigurationPage> = []
    /// Read the snapshot again, after something was added from a catalogue (059).
    var refresh: () async -> Void = {}
    /// The Skills, Personas or Workflows page has edits not saved (#2745): the container's,
    /// when it has ways out of its own to guard, such as Folder Settings' Done.
    var unsaved: Binding<Bool>?
    @State private var ownUnsaved = false
    @State private var leaving: UnsavedLeave?
    /// How many files the Workflows page lists (#2760): the snapshot has no workflows, so the
    /// pane reads them as that page does, again on each page change to see an added one.
    @State private var workflows: Int?

    private var unsavedEdits: Binding<Bool> { unsaved ?? $ownUnsaved }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // `~/.agents` is this Mac's; some parts go to the other machines (#2704).
            if showsScope {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(UserScopeWords.thisMacOnly).appText(.supporting).fontWeight(.semibold)
                        Text(UserScopeWords.agentConfigurationFollows)
                            .appText(.fine).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                Divider()
            }
            HStack(spacing: 0) {
                AgentConfigurationPageList(snapshot: snapshot, workflows: workflows, chosen: page, waiting: waiting,
                                           choose: choose, place: place)
                chosenPage
            }
        }
        .task(id: page) { await countWorkflows() }
        .discardUnsavedQuestion($leaving)
    }

    /// Another page drops the open file's edits, so it asks first.
    private func choose(_ next: AgentConfigurationPage) {
        guard next != page else { return }
        $leaving.leave(unsaved: unsavedEdits.wrappedValue) { page = next }
    }

    private func countWorkflows() async {
        let folder: URL? = if case .folder(let folder) = place { folder } else { nil }
        let host: MachineRef = folder == nil ? .mac : model.selectedFolderHost
        guard let files = await model.agentConfigEditorFiles(on: host, folder: folder, kind: .workflows) else { return }
        workflows = files.count
    }

    private var showsScope: Bool {
        if case .you = place { return true }
        return false
    }

    private var chosenPage: some View {
        Group {
            if let snapshot {
                if !snapshot.laidOut {
                    SharedOffState()
                } else if page == .overview, snapshot.isEmpty {
                    SharedEmptyState(place: place, home: snapshot.home)
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
        case .overview: AgentConfigurationOverview(place: place, snapshot: snapshot, workflows: workflows, page: $page)
        case .instructions: AgentsSetupPage { AgentsInstructionsSection(place: place) }.task { await refresh() }
        case .skills:
            AgentConfigurationFilesPage(place: place, kind: .skills, unsaved: unsavedEdits,
                                        looks: snapshot.needsALook.filter { $0.page == .skills })
        case .personas: AgentConfigurationFilesPage(place: place, kind: .personas, unsaved: unsavedEdits)
        case .workflows: AgentConfigurationFilesPage(place: place, kind: .workflows, unsaved: unsavedEdits)
        case .mcp: AgentsSetupPage { FolderMCPSection(place: place) }.task { await refresh() }
        case .plugins: AgentsSetupPage { AgentsPluginsSection(place: place) }.task { await refresh() }
        case .other: AgentConfigurationOtherFiles(place: place, snapshot: snapshot)
        }
    }
}

/// Every page, in the order the pane lists them.
enum AgentConfigurationPage: String, Hashable, CaseIterable {
    case overview, instructions, skills, personas, workflows, mcp, plugins, other

    init(_ page: DaemonAPI.Look.Page) {
        switch page {
        case .instructions: self = .instructions
        case .skills: self = .skills
        case .mcp: self = .mcp
        case .plugins: self = .plugins
        case .other: self = .other
        }
    }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .instructions: "Instructions"
        case .skills: "Skills"
        case .personas: "Personas"
        case .workflows: "Workflows"
        case .mcp: "Connectors"
        case .plugins: "Plugins"
        case .other: "Other files"
        }
    }

    /// What its line counts, if anything; nil while the MCP file can't be read, or before
    /// the workflow files are counted.
    func count(in snapshot: DaemonAPI.SharedSnapshot, workflows: Int?) -> Int? {
        switch self {
        case .overview: nil
        case .instructions: snapshot.instructions?.exists == true ? 1 : 0
        case .skills: snapshot.skills.count
        case .personas: snapshot.otherFiles.filter { $0.kind == .persona }.count
        case .workflows: workflows
        case .mcp: snapshot.mcp.problem == nil ? snapshot.mcp.servers.count : nil
        case .plugins: snapshot.plugins.count
        case .other: snapshot.otherFiles.filter { $0.kind != .persona }.count
        }
    }

    func warns(in snapshot: DaemonAPI.SharedSnapshot) -> Bool {
        switch self {
        case .overview, .other, .personas, .workflows: false
        case .instructions: snapshot.warns(.instructions)
        case .skills: snapshot.warns(.skills)
        case .mcp: snapshot.warns(.mcp)
        case .plugins: snapshot.warns(.plugins)
        }
    }
}

extension AgentsPlace {
    /// The folder's name as a person writes it.
    var folderName: String {
        switch self {
        case .you: "~/.agents"
        case .folder: ".agents"
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

/// Frame H: the folder is there and empty. The other pages are still listed, so a skill
/// or a server can be added from them.
private struct SharedEmptyState: View {
    let place: AgentsPlace
    let home: String

    var body: some View {
        VStack(spacing: 14) {
            // Decorative: the tab's own symbol, large, above the words that say it all.
            Image(systemName: SettingsPane.agentConfiguration.symbol).glyph(size: 34).foregroundStyle(.secondary)
            Text("Nothing here yet").appText(.title)
            Text(words)
                .appText(.supporting).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Reveal \(place.folderName) in Finder") { SharedFiles.reveal(home) }.buttonStyle(.paper)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var words: String {
        switch place {
        case .you:
            "Put things in ~/.agents once and every agent gets them, on every runtime: AGENTS.md for instructions · skills/ · personas/ · workflows/ · mcp.json for connectors · plugins/"
        case .folder:
            "Put things in this folder’s .agents and every agent here gets them, and everyone who clones it: skills/ · personas/ · workflows/ · mcp.json for connectors · plugins/. Its instructions are AGENTS.md at the top of the folder."
        }
    }
}

/// A copy of the app with no personal home of its own (research R4).
private struct SharedOffState: View {
    var body: some View {
        VStack(spacing: 10) {
            // Decorative: the tab's own symbol, large, above the words that say it all.
            Image(systemName: SettingsPane.agentConfiguration.symbol).glyph(size: 34).foregroundStyle(.secondary)
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
    /// model when it starts. Your ~/.agents and a folder's files are on this Mac.
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

/// Agent Configuration's pages, as a list inside its pane in Settings and in Folder
/// Settings (#754, #1076). Overview only, until the folder is laid out.
struct AgentConfigurationPageList: View {
    let snapshot: DaemonAPI.SharedSnapshot?
    var workflows: Int? = nil
    let chosen: AgentConfigurationPage
    var waiting: Set<AgentConfigurationPage> = []
    let choose: (AgentConfigurationPage) -> Void
    var place: AgentsPlace = .you

    private var pages: [AgentConfigurationPage] { AgentConfigurationPage.allCases }

    var body: some View {
        PageList {
            ForEach(pages, id: \.self) { each in
                if each == .overview || snapshot?.laidOut == true {
                    line(each)
                }
            }
        }
    }

    private func line(_ each: AgentConfigurationPage) -> some View {
        let lit = chosen == each
        let count = snapshot.flatMap { each.count(in: $0, workflows: workflows) }
        let warns = snapshot.map { each.warns(in: $0) } ?? false
        return PageLine(title: each.title, lit: lit,
                        label: each.title + (count.map { ", \($0)" } ?? "") + (warns ? ", needs a look" : "")
                            + (waiting.contains(each) ? ", waiting for your OK" : ""),
                        action: { choose(each) }) {
            if warns {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(lit ? .white : SharedInk.attention)
            }
            if waiting.contains(each) {
                Circle().fill(StateTint.attention.style(or: .secondary)).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            PageCount(count: count, lit: lit)
        }
    }
}
