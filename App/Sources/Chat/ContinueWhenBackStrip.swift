import AgentsKitCore
import SwiftUI

/// Under a chat paused by a spent allowance (#1859): Continue at the reset time, or, once
/// asked, when it continues and a Cancel. In the chat's actions, where Carry on is.
struct ContinueWhenBackStrip: View {
    @Environment(AppModel.self) private var model
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
                .help("This chat no longer carries on by itself")
            } else {
                Spacer(minLength: 0)
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
    }
}
