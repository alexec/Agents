import AgentsKitCore
import SwiftUI

/// Whether the project's shell is showing under the page, and how tall it is (#418).
///
/// The window's, as the inspector's frame is: the height is one person's preference,
/// kept in `UserDefaults`, and open or not is about now. It follows the project, not the
/// agent: picking another agent in the project leaves it as it is.
@MainActor
@Observable
final class ProjectTerminalFrame {
    static let minimumHeight: Double = 120
    static let defaultHeight: Double = 260
    /// What the page above keeps, whatever the panel was dragged to.
    static let minimumPageHeight: Double = 200

    private static let heightKey = "projectTerminal.height"
    private let defaults: UserDefaults

    var isOpen = false
    /// Set when it is opened, so the shell takes the keyboard; cleared once it has.
    var wantsFocus = false

    var height: Double {
        didSet { defaults.set(height, forKey: Self.heightKey) }
    }

    /// Each project's tabs, so another project and back finds the one that was in front.
    private var tabs: [ProjectKey: ProjectShellTabs] = [:]

    func tabs(for project: ProjectKey) -> ProjectShellTabs {
        if let existing = tabs[project] { return existing }
        let fresh = ProjectShellTabs()
        tabs[project] = fresh
        return fresh
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        height = max((defaults.object(forKey: Self.heightKey) as? Double) ?? Self.defaultHeight, Self.minimumHeight)
    }

    /// Control-`: shown and typed in, or put away. Putting it away ends nothing.
    func toggle() {
        isOpen.toggle()
        wantsFocus = isOpen
    }

    /// The panel's height in a page this tall, leaving the page its share.
    func height(inPageOf total: Double) -> Double {
        min(max(height, Self.minimumHeight), max(Self.minimumHeight, total - Self.minimumPageHeight))
    }
}

/// The tabs over a project's shells, as an agent's Terminal pane has over its own.
@MainActor
@Observable
final class ProjectShellTabs {
    var shells = [0]
    var front = 0
    var titles: [Int: String] = [:]
    /// A tab just opened, which takes the keyboard; cleared once it has.
    var toFocus: Int?
    /// False when the project's host is too old to hold more than the one.
    var canOpenMore = true
}

/// The selected project's shells, in its own folder, under whatever page is open (#418),
/// one to a tab.
///
/// Not an agent's: they open with no agent chosen, and choosing one does not move them
/// into that agent's folder or worktree. Another project shows that project's shells.
/// Like an agent's, they are the daemon's: hiding the panel, changing project, closing
/// the window or quitting leave them running, and closing a tab is the one thing that
/// ends one. Closing the last puts the panel away; the next Control-` starts a new one.
struct ProjectTerminalPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(ProjectTerminalFrame.self) private var frame
    let project: DaemonAPI.ProjectSummary
    let pageHeight: Double

    private var tabs: ProjectShellTabs { frame.tabs(for: project.key) }

    var body: some View {
        let tabs = tabs
        VStack(spacing: 0) {
            HeightHandle(pageHeight: pageHeight)
            bar(tabs)
            Divider()
            // Every tab's screen is built and the hidden ones kept alive, as in an
            // agent's pane, so a tab comes back with its screen and scrollback as it was.
            ZStack {
                ForEach(tabs.shells, id: \.self) { shell in
                    ShellScreen(id: ProjectShell.id(for: project.folder), home: nil,
                                acquire: { model.acquireProjectShell(project.key, shell: shell) },
                                isFront: tabs.front == shell,
                                wantsFocus: tabs.toFocus == shell || (frame.wantsFocus && tabs.front == shell),
                                focused: {
                                    if tabs.toFocus == shell { tabs.toFocus = nil }
                                    if tabs.front == shell { frame.wantsFocus = false }
                                },
                                titled: { tabs.titles[shell] = $0 },
                                newTab: open, closeTab: { close(shell) })
                        .opacity(tabs.front == shell ? 1 : 0)
                        .allowsHitTesting(tabs.front == shell)
                }
            }
            // A screen per project: another project attaches its own shells.
            .id(project.key)
        }
        .frame(height: frame.height(inPageOf: pageHeight))
        .background(Paper.ground)
        // Asked each time the panel shows a project: a tab opened or closed on the phone
        // meanwhile is found.
        .task(id: project.key) {
            guard let held = await model.projectShellNumbers(project.key) else {
                tabs.canOpenMore = false
                return
            }
            tabs.canOpenMore = true
            // None held: the first screen starts one.
            tabs.shells = held.isEmpty ? [0] : held
            if !tabs.shells.contains(tabs.front) { tabs.front = tabs.shells.first ?? 0 }
        }
    }

    private func bar(_ tabs: ProjectShellTabs) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "apple.terminal")
                .foregroundStyle(.secondary)
            Text("Terminal")
                .appText(.supporting).fontWeight(.semibold)
            Text(project.name)
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(project.folder.path(percentEncoded: false))
            ShellTabs(shells: tabs.shells, titles: tabs.titles, front: tabs.front,
                      canOpenMore: tabs.canOpenMore,
                      select: { shell in
                          tabs.front = shell
                          tabs.toFocus = shell
                      },
                      open: open, close: close)
            Button {
                frame.isOpen = false
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .help("Hide the project’s shells (⌃`). They keep running.")
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
    }

    /// The host numbers the new shell, so a tab opened on the phone at the same moment
    /// never gets the same one.
    private func open() {
        let tabs = tabs
        Task {
            let next = await model.openProjectShell(project.key) ?? ((tabs.shells.max() ?? -1) + 1)
            if !tabs.shells.contains(next) { tabs.shells.append(next) }
            tabs.front = next
            tabs.toFocus = next
        }
    }

    /// Closing a tab ends its shell. Closing the last puts the panel away, and the next
    /// Control-` starts a new one.
    private func close(_ shell: Int) {
        let tabs = tabs
        guard let index = tabs.shells.firstIndex(of: shell) else { return }
        tabs.shells.remove(at: index)
        tabs.titles[shell] = nil
        Task { await model.closeShell(agentID: ProjectShell.id(for: project.folder), shell: shell) }
        if tabs.shells.isEmpty {
            frame.isOpen = false
            tabs.shells = [0]
            tabs.front = 0
        } else if tabs.front == shell {
            tabs.front = tabs.shells[min(index, tabs.shells.count - 1)]
            tabs.toFocus = tabs.front
        }
    }
}

/// The panel's top edge, dragged up to make it taller. Its own strip rather than drawn
/// over the shell, for the reason the inspector's handle gives: AppKit's views sit above
/// anything SwiftUI draws on them.
private struct HeightHandle: View {
    @Environment(ProjectTerminalFrame.self) private var frame
    let pageHeight: Double
    @State private var heightWhenDragBegan: Double?

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(height: 6)
            .overlay { Divider() }
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: .top))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = heightWhenDragBegan ?? frame.height(inPageOf: pageHeight)
                        heightWhenDragBegan = start
                        frame.height = min(max(start - value.translation.height, ProjectTerminalFrame.minimumHeight),
                                           max(ProjectTerminalFrame.minimumHeight,
                                               pageHeight - ProjectTerminalFrame.minimumPageHeight))
                    }
                    .onEnded { _ in heightWhenDragBegan = nil }
            )
            .accessibilityLabel("Resize the project’s shell")
    }
}
