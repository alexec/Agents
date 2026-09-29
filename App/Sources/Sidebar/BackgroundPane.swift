import AgentsKitCore
#if !AGENTS_STORE
import AgentsKit
#endif
import SwiftUI

/// What an agent has had in the background, and a subagent's own steps (057, frame C).
///
/// A subagent's words and work arrive under a session of its own, and the chat keeps
/// only the agent's. This is where the subagent's are: what it was asked, each tool
/// call, and its report. The list is everything the agent has had running lately, so a
/// finished subagent can still be read.
struct BackgroundPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ThinkingDisplay.defaultsKey) private var showsThinking = false
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
                                  showsThinking: showsThinking,
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
            output: { item in Task { await BackgroundOutput.open(item, of: agent, model: model) } })
    }
}

/// A task's output file, opened in TextEdit: it has no extension anything else claims,
/// and it is the runtime's file, not inside the agent's folders.
enum BackgroundOutput {
    /// This Mac's file opens where it is. Another host's is read through `files/read`
    /// and opened from what came back (058, R11). A path the host will not give is
    /// left unopened: it is not on this disk.
    @MainActor
    static func open(_ item: BackgroundItem, of agent: Agent, model: AppModel) async {
        guard let path = item.outputFilePath else { return }
        let url = URL(fileURLWithPath: path)
        let local: URL
        if model.isOnThisMac(agent.host) {
            local = url
        } else if let text = await model.textFile(at: url, on: agent.host, agentID: agent.id) {
            let ext = url.pathExtension.isEmpty ? "txt" : url.pathExtension
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("agents-output-\(item.id)")
                .appendingPathExtension(ext)
            guard (try? text.write(to: temp, atomically: true, encoding: .utf8)) != nil else { return }
            local = temp
        } else {
            return
        }
        // Async because this function already is: the synchronous open is not the one
        // a concurrent context is offered.
        try? await NSWorkspace.shared.open([local],
                                            withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                            configuration: NSWorkspace.OpenConfiguration())
    }
}
