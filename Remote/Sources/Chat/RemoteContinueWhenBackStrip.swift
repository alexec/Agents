import AgentsKitCore
import SwiftUI

/// Over a chat paused by a spent allowance (#1859): Continue at the reset time, or, once
/// asked, when it continues and a Cancel, as the Mac's strip has them.
struct RemoteContinueWhenBackStrip: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent
    /// An Auto session's next runtime (#2658, FR-022): its button continues there, by tap only.
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
            } else {
                if let next {
                    Button(LevelWords.continueOn(PromptWords.runtimeName(next))) {
                        Task { await model.continueInNew(agent.id, onAuto: true) }
                    }
                }
                Button {
                    Task { await model.continueWhenBack(agent.id) }
                } label: {
                    Label(ContinueWhenBackWords.button(resetsAt: model.runtimeAllowances?.resetsAt(agent.runtimeID)),
                          systemImage: ContinueWhenBackWords.symbol)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .appText(.fine)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .task(id: agent.id) {
            next = await model.autoPreview(for: agent)?.runtimeID.flatMap { $0 == agent.runtimeID ? nil : $0 }
        }
    }
}
