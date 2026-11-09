import AgentsKitCore
import SwiftUI

/// The agent browser or a simulator taken over (#4138, #4141), from Open on a live tile or
/// Open the page on a hand-off, as the Mac's take-over window: a scene of its own on an
/// iPad, a full-screen cover on an iPhone, not a pane beside the chat. The browser watches
/// (`browser/watch`) while it is open, so it gets frames whoever drives; over it, a
/// hand-off's step with Done and Can't do it.
struct TakeOverView: View {
    @Environment(RemoteModel.self) private var model
    let key: TakeOverKey?
    /// Closes the cover on an iPhone; nil in a scene of its own, which the system closes.
    var close: (() -> Void)?

    private var agent: Agent? { key.flatMap { model.work.agent($0.agentID) } }

    var body: some View {
        NavigationStack {
            Group {
                if let key, let agent {
                    content(key.source, agent: agent)
                } else {
                    ContentUnavailableView("This session is gone", systemImage: "questionmark.folder")
                }
            }
            .navigationTitle(agent?.title ?? "")
            .navigationSubtitle(key?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let close {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark", action: close)
                    }
                }
            }
        }
        .paperGround()
        .environment(\.inTakeOver, true)
    }

    @ViewBuilder
    private func content(_ source: LiveSource, agent: Agent) -> some View {
        switch source {
        case .simulator:
            if model.host(agent.host, has: Capability.simulators1) {
                SimulatorPaneView(calls: model.simulatorCalls(for: agent.id))
            } else {
                HostNeedsUpdateView()
            }
        case .browser, .screen:
            if model.host(agent.host, has: Capability.browser1) {
                VStack(spacing: 0) {
                    if let request = model.work.elicitation(for: agent.id), request.handOff != nil {
                        ScrollView {
                            ElicitationSheet(request: request)
                                .id(request.id)
                                .padding(12)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .fixedSize(horizontal: false, vertical: true)
                        Divider()
                    }
                    AgentBrowserPane(agent: agent)
                }
            } else {
                HostNeedsUpdateView()
            }
        }
    }
}

/// Opens a take-over (#4141): a scene of its own where the device has more than one, else
/// the cover over the app.
@MainActor
struct OpenTakeOver {
    let supportsMultipleWindows: Bool
    let openWindow: OpenWindowAction
    let model: RemoteModel

    func callAsFunction(_ key: TakeOverKey) {
        if supportsMultipleWindows {
            openWindow(id: TakeOverKey.sceneID, value: key)
        } else {
            model.takeOver = key
        }
    }
}

/// The take-over on an iPhone (#4141), over the app, with Close. Not drawn while a folder
/// shown alone covers the app: that cover draws it over itself.
struct TakeOverCover: ViewModifier {
    @Environment(RemoteModel.self) private var model
    /// Drawn over a folder shown alone (#1089), not the app's root.
    var overFolder = false

    func body(content: Content) -> some View {
        content.fullScreenCover(item: Binding(get: { overFolder == (model.phoneFolder != nil) ? model.takeOver : nil },
                                              set: { model.takeOver = $0 })) { key in
            TakeOverView(key: key, close: { model.takeOver = nil })
                .environment(model)
        }
    }
}
