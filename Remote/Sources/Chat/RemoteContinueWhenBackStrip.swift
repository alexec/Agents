import AgentsKitCore
import SwiftUI

/// Over a chat paused by a spent allowance (#1859): Continue at the reset time, or, once
/// asked, when it continues and a Cancel, as the Mac's strip has them.
struct RemoteContinueWhenBackStrip: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent

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
    }
}
