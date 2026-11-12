import AgentsKitCore
import SwiftUI

/// Over a chat paused by a spent allowance (#1859): Continue at the reset time, or, once
/// asked, when it continues and a Cancel, as the Mac's strip has them: a neutral banner
/// (#4737).
struct RemoteContinueWhenBackStrip: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent
    /// An Auto session's next runtime (#2658, FR-022): its button continues there, by tap only.
    @State private var next: String?

    var body: some View {
        // Neutral (#4737): the chat carries on by itself, or will when asked.
        let line = ContinueWhenBackWords.line(agent)
        PaneBanner(tone: .neutral, symbol: ContinueWhenBackWords.symbol, line ?? ContinueWhenBackWords.paused) {
            if line != nil {
                Button(ContinueWhenBackWords.cancel) {
                    Task { await model.cancelContinue(agent.id) }
                }
            } else {
                if let next {
                    Button(LevelWords.continueOn(PromptWords.runtimeName(next))) {
                        Task { await model.continueInNew(agent.id, onAuto: true) }
                    }
                }
                Button(ContinueWhenBackWords.button(resetsAt: model.runtimeAllowances?.resetsAt(agent.runtimeID))) {
                    Task { await model.continueWhenBack(agent.id) }
                }
            }
        }
        .paneBannerInset()
        .remoteBannerGround()
        .task(id: agent.id) {
            next = await model.autoPreview(for: agent)?.runtimeID.flatMap { $0 == agent.runtimeID ? nil : $0 }
        }
    }
}
