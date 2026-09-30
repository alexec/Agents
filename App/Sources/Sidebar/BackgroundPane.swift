import AgentsKit
import SwiftUI

/// What an agent has had in the background, and a subagent's own steps (057, frame C).
///
/// A subagent's words and work arrive under a session of its own, and the chat keeps
/// only the agent's. This is where the subagent's are: what it was asked, each tool
/// call, and its report. The list is everything the agent has had running lately, so a
/// finished subagent can still be read.
struct BackgroundPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage(TurnDisplay.defaultsKey) private var turnDetail = TurnDisplay.initial
    let agent: Agent
    let state: AgentPaneState

    private var chosen: BackgroundItem? {
        state.subagent.flatMap { id in agent.background.first { $0.id == id } }
    }

    var body: some View {
        Group {
            if let chosen {
                SubagentStepsView(item: chosen,
                                  entries: model.selection == agent.id ? model.entries : [],
                                  showsThinking: turnDetail == .details,
                                  back: { state.subagent = nil })
            } else if agent.background.isEmpty {
                VStack(spacing: 8) {
                    Text("Nothing in the background")
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                    Text("Shells and subagents the agent starts while it works are listed here.")
                        .appText(.fine)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(agent.background.reversed()) { item in
                        BackgroundItemRow(item: item, actions: actions, stacked: true)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var actions: BackgroundActions {
        BackgroundActions(
            stop: { [model, agent] item in await model.stopBackground(item, of: agent.id) },
            steps: { [state] item in state.subagent = item.id },
            output: { item in BackgroundOutput.open(item) })
    }
}

/// A task's output file, opened in TextEdit: it has no extension anything else claims,
/// and it is the runtime's file, not inside the agent's folders.
enum BackgroundOutput {
    @MainActor
    static func open(_ item: BackgroundItem) {
        guard let path = item.outputFilePath else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)],
                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }
}
