import AgentsKit
import SwiftUI

/// The column on the right of the conversation.
///
/// It is the user's, not the agent's. What it shows follows the selected agent, and
/// when it is closed none of it is running: no folder watch, no web view, no shell
/// attached. That is FR-006 kept by construction rather than by care, because the whole
/// subtree is absent rather than hidden.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(SidebarFrame.self) private var frame
    @Environment(SidebarStates.self) private var states

    /// The width of the whole window, so the column can refuse to take more than its
    /// share.
    let windowWidth: Double

    var body: some View {
        HStack(spacing: 0) {
            ResizeHandle(windowWidth: windowWidth)
            content
                .frame(width: frame.width)
        }
        .background(Paper.ground)
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let agent = model.selectedAgent {
                pane(for: agent)
                    // Rebuilt per agent: switching agents switches what the sidebar
                    // shows, which is FR-002. The state each pane returns to is kept
                    // in SidebarStates and outlives this identity change.
                    .id(agent.id)
            } else {
                NoAgent()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Picker("", selection: Binding(get: { frame.pane },
                                          set: { frame.pane = $0 })) {
                // Words rather than glyphs: a folder, a terminal, a globe and a tray
                // had to be learnt, and "Exchanged" has no glyph that says it.
                ForEach(SidebarPane.allCases) { pane in
                    Text(pane.title)
                        .help(pane.title)
                        .tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // No close button here. The toolbar's toggle already closes it, and two
            // identical icons a few inches apart are one too many.
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func pane(for agent: Agent) -> some View {
        let state = states.state(for: agent.id)
        // Every pane is built, and the hidden ones are kept alive rather than torn
        // down, so moving between panes does not lose a page, a folder or a shell
        // (FR-022, FR-031). Only the chosen one is on screen.
        ZStack {
            FilesPane(agent: agent, state: state)
                .opacity(frame.pane == .files ? 1 : 0)
                .allowsHitTesting(frame.pane == .files)
            ChangesPane(agent: agent, state: state)
                .opacity(frame.pane == .changes ? 1 : 0)
                .allowsHitTesting(frame.pane == .changes)
            TerminalPane(agent: agent, state: state)
                .opacity(frame.pane == .terminal ? 1 : 0)
                .allowsHitTesting(frame.pane == .terminal)
            BrowserPane(agent: agent, state: state)
                .opacity(frame.pane == .browser ? 1 : 0)
                .allowsHitTesting(frame.pane == .browser)
            ArtifactsPane(agent: agent, state: state)
                .opacity(frame.pane == .artifacts ? 1 : 0)
                .allowsHitTesting(frame.pane == .artifacts)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What the sidebar says when there is no agent to show. Not five blank panes (FR-007).
private struct NoAgent: View {
    var body: some View {
        VStack(spacing: 8) {
            // Deliberately not the sidebar glyph: that one means the control in the
            // toolbar, and repeating it here reads as a button that does nothing.
            Image(systemName: "square.dashed")
                .appText(.title)
                .foregroundStyle(.tertiary)
            Text("No agent chosen")
                .appText(.reading).fontWeight(.semibold)
            Text("Start an agent, or pick one from the list, and its folder, a shell in that folder, and what it hands over all appear here.")
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The draggable edge. Dragging left widens the column, which is the direction the
/// pointer moves, so the handle follows the hand rather than the number.
///
/// The grip is laid out as a strip of its own rather than drawn over its neighbours.
/// A shell and a web page are AppKit views, and those sit above anything SwiftUI draws
/// over them, so a grip that overlapped the pane only worked on one side of the line.
/// And the drag is read in the window's coordinates: the handle moves as the column
/// widens, and a distance measured from something that is itself moving is measured
/// twice.
private struct ResizeHandle: View {
    @Environment(SidebarFrame.self) private var frame
    let windowWidth: Double
    @State private var widthWhenDragBegan: Double?

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 8)
            .overlay { Divider() }
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: .leading))
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = widthWhenDragBegan ?? frame.width
                        widthWhenDragBegan = start
                        frame.setWidth(start - value.translation.width,
                                       inWindowOf: windowWidth)
                    }
                    .onEnded { _ in widthWhenDragBegan = nil }
            )
            .accessibilityLabel("Resize the sidebar")
    }
}

/// The control that opens the column, and says why it cannot when the window is too
/// narrow for the conversation and the sidebar both.
struct SidebarToggle: View {
    @Environment(SidebarFrame.self) private var frame
    let windowWidth: Double

    private var fits: Bool { SidebarFrame.fits(inWindowOf: windowWidth) }

    var body: some View {
        Button {
            guard fits else { return }
            if frame.isOpen { frame.isOpen = false } else { frame.open() }
        } label: {
            Image(systemName: "sidebar.trailing")
        }
        .disabled(!fits && !frame.isOpen)
        .help(fits
              ? (frame.isOpen ? "Close the sidebar" : "Show the agent's files, a shell, a browser and what has been exchanged")
              : "The window is too narrow to show the sidebar and the conversation at once. Make it wider.")
    }
}
