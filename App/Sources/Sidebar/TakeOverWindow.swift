import AgentsKitCore
import SwiftUI

/// The agent browser or a simulator in a window of its own (#4138, #4141), from Open on a
/// live tile or Open the page on a hand-off: where the person uses what the agent drives,
/// not in the side column. The browser window watches (`browser/watch`) while it is open,
/// so it gets frames whoever drives; over it, a hand-off's step with Done and Can't do it.
struct TakeOverWindow: View {
    @Environment(AppModel.self) private var model
    let key: TakeOverKey?

    private var agent: Agent? { key.flatMap { model.work.agent($0.agentID) } }

    var body: some View {
        Group {
            if let key, let agent {
                content(key.source, agent: agent)
            } else {
                ContentUnavailableView("This session is gone", systemImage: "questionmark.folder",
                                       description: Text("Close this window."))
            }
        }
        .paperGround()
        .frame(minWidth: 480, minHeight: 360)
        .navigationTitle(AppCheckout.windowTitle(agent?.title))
        .navigationSubtitle(key?.title ?? "")
        .tint(Paper.accent)
        .environment(\.inTakeOver, true)
    }

    @ViewBuilder
    private func content(_ source: LiveSource, agent: Agent) -> some View {
        switch source {
        case .simulator:
            if model.host(agent.host, has: Capability.simulators1) {
                SimulatorPaneView(calls: model.simulatorCalls(for: agent.id), isVisible: true)
            } else {
                HostNeedsUpdateView()
            }
        case .browser, .screen:
            if model.host(agent.host, has: Capability.browser1) {
                VStack(spacing: 0) {
                    if let request = model.work.elicitation(for: agent.id), request.handOff != nil {
                        ElicitationView(request: request)
                            .id(request.id)
                            .padding(12)
                        Divider()
                    }
                    AgentBrowserPane(agent: agent, isVisible: true)
                }
            } else {
                HostNeedsUpdateView()
            }
        }
    }
}
