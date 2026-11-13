import AgentsKitCore
import SwiftUI

/// The allowance's strip (#5034, fourth of the session's strips; #1859): Continue at the reset
/// time, or, once asked, when it continues and a Cancel, as the Mac's strip has them.
struct RemoteContinueWhenBackStrip: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent
    /// An Auto session's next runtime (#2658, FR-022): its button continues there, by tap only.
    @State private var next: String?

    @MainActor
    static func isShown(_ agent: Agent, model: RemoteModel) -> Bool {
        agent.state != .archived && (ContinueWhenBackWords.offers(agent) || agent.continueWhenBack != nil)
            && model.host(agent.host, has: Capability.chatContinueWhenBack1)
    }

    var body: some View {
        // Grey once asked: the chat carries on by itself. Orange until then: it cannot go on.
        let line = ContinueWhenBackWords.line(agent)
        Group {
            if let line {
                Strip(tone: .neutral, symbol: ContinueWhenBackWords.symbol, line: line,
                      second: StripButton(title: ContinueWhenBackWords.cancel) {
                          Task { await model.cancelContinue(agent.id) }
                      })
            } else {
                Strip(tone: .warning, symbol: ContinueWhenBackWords.symbol, line: ContinueWhenBackWords.paused,
                      primary: StripButton(title: ContinueWhenBackWords.button(resetsAt: model.runtimeAllowances?.resetsAt(agent.runtimeID))) {
                          Task { await model.continueWhenBack(agent.id) }
                      },
                      second: next.map { next in
                          StripButton(title: LevelWords.continueOn(PromptWords.runtimeName(next))) {
                              Task { await model.continueInNew(agent.id, onAuto: true) }
                          }
                      })
            }
        }
        .task(id: agent.id) {
            next = await model.autoPreview(for: agent)?.runtimeID.flatMap { $0 == agent.runtimeID ? nil : $0 }
        }
    }
}
