import AgentsKitCore
import SwiftUI

/// The conversation, and the pane beside it or over it (034).
///
/// Where the screen holds the conversation at its reading width and a pane that still
/// reads, the pane is a column on the right, as on the Mac. Otherwise it is pushed over
/// the conversation, one Back from it, and the conversation keeps its place because it
/// is never taken down. The choice is `PanePlacement`'s, from the width alone.
struct PaneHost<Chat: View>: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent
    @ViewBuilder var chat: Chat

    @State private var width: Double = 0

    private var state: PaneState { model.panes.state(for: agent.id) }
    private var placement: PanePlacement {
        PanePlacement.decide(width: width, preferredPaneWidth: model.panes.preferredColumnWidth)
    }

    var body: some View {
        HStack(spacing: 0) {
            chat
            if case .column(let paneWidth) = placement, state.pane != nil {
                ColumnHandle(width: paneWidth, total: width)
                PaneView(agent: agent, isColumn: true)
                    .frame(width: paneWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.snappy(duration: 0.2), value: state.pane)
        .onGeometryChange(for: Double.self) { $0.size.width } action: { width = $0 }
        .navigationDestination(isPresented: fullScreen) {
            PaneView(agent: agent, isColumn: false)
                .paperGround()
        }
    }

    /// Pushed when there is no room for a column. Setting it false is the Back button,
    /// which closes the pane; the next Panes tap opens it where it was.
    private var fullScreen: Binding<Bool> {
        Binding(get: { placement == .fullScreen && state.pane != nil },
                set: { if !$0 && placement == .fullScreen { state.pane = nil } })
    }
}

/// The rule between the conversation and the column, which can be dragged to size it.
private struct ColumnHandle: View {
    @Environment(RemoteModel.self) private var model
    let width: Double
    let total: Double
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: PanePlacement.divider)
            .overlay {
                // Wider than it looks, so a finger finds it.
                Color.clear
                    .frame(width: 24)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let from = start ?? width
                                start = from
                                model.panes.preferredColumnWidth = from - value.translation.width
                            }
                            .onEnded { _ in start = nil }
                    )
            }
            .accessibilityHidden(true)
    }
}

/// One pane, with the switch between them at its top.
struct PaneView: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent
    let isColumn: Bool

    private var state: PaneState { model.panes.state(for: agent.id) }

    /// What can be switched to. The Page once there is a page; the Terminal while the
    /// Mac can give one; never a Browser (FR-030).
    private var offered: [Pane] {
        if model.macLacksPanes { return [.exchanged] }
        return Pane.allCases.filter { $0 != .page || state.pagePath != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !isColumn { StaleBanner() }
        }
        .navigationTitle(state.pane?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var bar: some View {
        HStack(spacing: 8) {
            Picker("Pane", selection: Binding(get: { state.pane ?? state.defaultPane },
                                              set: { state.show($0) })) {
                ForEach(offered) { pane in
                    Text(pane.title).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            if isColumn {
                Button {
                    state.pane = nil
                } label: {
                    Label("Close", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .accessibilityHint("Closes the pane beside the conversation")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if model.isAway {
            // Away, none of the three open: they stream too much for iCloud (046, look B).
            NeedsSameNetworkView()
        } else if model.macLacksPanes {
            VStack(spacing: 0) {
                Text("Update Agents on your Mac to read files and use the terminal here.")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .padding(12)
                ArtifactsList()
            }
        } else {
            switch state.pane ?? state.defaultPane {
            case .page:
                PagePane(agent: agent)
            case .files:
                FilesPane(agent: agent)
            case .terminal:
                TerminalPane(agent: agent)
            case .exchanged:
                ArtifactsList()
            }
        }
    }
}
