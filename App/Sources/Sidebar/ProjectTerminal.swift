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

/// A shell in the selected project's folder, under whatever page is open (#418).
///
/// Not an agent's: it opens with no agent chosen, and choosing one does not move it into
/// that agent's folder or worktree. Another project shows that project's shell. Like an
/// agent's, it is the daemon's: hiding the panel, changing project, closing the window
/// or quitting leave it running, and the close button is the one thing that ends it.
struct ProjectTerminalPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(ProjectTerminalFrame.self) private var frame
    let project: DaemonAPI.ProjectSummary
    let pageHeight: Double

    var body: some View {
        VStack(spacing: 0) {
            HeightHandle(pageHeight: pageHeight)
            bar
            Divider()
            ShellScreen(id: ProjectShell.id(for: project.folder), home: nil,
                        acquire: { model.acquireProjectShell(project.key) },
                        isFront: true, wantsFocus: frame.wantsFocus,
                        focused: { frame.wantsFocus = false },
                        titled: { _ in },
                        newTab: {}, closeTab: close)
                // A screen per project: another project attaches its own shell.
                .id(project.key)
        }
        .frame(height: frame.height(inPageOf: pageHeight))
        .background(Paper.ground)
    }

    private var bar: some View {
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
            Spacer()
            Button {
                frame.isOpen = false
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .help("Hide the project’s shell (⌃`). It keeps running.")
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("End the project’s shell")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    /// Closing is what ends it, as closing an agent's last tab does; the next Control-`
    /// starts a new one.
    private func close() {
        frame.isOpen = false
        Task { await model.closeShell(agentID: ProjectShell.id(for: project.folder), shell: 0) }
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
