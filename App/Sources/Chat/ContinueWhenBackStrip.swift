import AgentsKitCore
import SwiftUI

/// Under a chat paused by a spent allowance (#1859): Continue at the reset time, or, once
/// asked, when it continues and a Cancel. In the chat's actions, where Carry on is.
struct ContinueWhenBackStrip: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    /// An Auto session's next runtime (#2658, FR-022): its button continues there, by press only.
    @State private var next: String?

    var body: some View {
        HStack(spacing: 8) {
            if let line = ContinueWhenBackWords.line(agent) {
                Label(line, systemImage: ContinueWhenBackWords.symbol)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(ContinueWhenBackWords.cancel) {
                    Task { await model.cancelContinue(agent.id) }
                }
                .help("This chat no longer carries on by itself")
            } else {
                Spacer(minLength: 0)
                if let next {
                    Button(LevelWords.continueOn(PromptWords.runtimeName(next))) {
                        Task { await model.continueInNew(agent.id, onAuto: true) }
                    }
                    .help("Starts a session on \(PromptWords.runtimeName(next)) that reads this one and carries on, with the same values.")
                }
                Button {
                    Task { await model.continueWhenBack(agent.id) }
                } label: {
                    Label(ContinueWhenBackWords.button(resetsAt: model.runtimeAllowances?.resetsAt(agent.runtimeID)),
                          systemImage: ContinueWhenBackWords.symbol)
                }
                .help(ContinueWhenBackWords.help)
            }
        }
        .buttonStyle(.paper)
        .appText(.fine)
        .chatColumn()
        .padding(.vertical, 8)
        .task(id: agent.id) {
            next = await model.autoPreview(for: agent)?.runtimeID.flatMap { $0 == agent.runtimeID ? nil : $0 }
        }
    }
}
