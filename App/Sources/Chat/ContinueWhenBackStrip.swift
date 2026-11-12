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
        // Neutral (#4737): the chat carries on by itself, or will when asked.
        let line = ContinueWhenBackWords.line(agent)
        let words = line ?? ContinueWhenBackWords.paused
        PaneBanner(tone: .neutral, symbol: ContinueWhenBackWords.symbol, words) {
            if line != nil {
                Button(ContinueWhenBackWords.cancel) {
                    Task { await model.cancelContinue(agent.id) }
                }
                .help("This chat no longer carries on by itself")
            } else {
                if let next {
                    Button(LevelWords.continueOn(PromptWords.runtimeName(next))) {
                        Task { await model.continueInNew(agent.id, onAuto: true) }
                    }
                    .help("Starts a session on \(PromptWords.runtimeName(next)) that reads this one and carries on, with the same values.")
                }
                Button(ContinueWhenBackWords.button(resetsAt: model.runtimeAllowances?.resetsAt(agent.runtimeID))) {
                    Task { await model.continueWhenBack(agent.id) }
                }
                .help(ContinueWhenBackWords.help)
            }
        }
        .chatColumn()
        .padding(.top, 8)
        .task(id: agent.id) {
            next = await model.autoPreview(for: agent)?.runtimeID.flatMap { $0 == agent.runtimeID ? nil : $0 }
        }
    }
}
