import AgentsKit
import SwiftUI

/// Where the next thing is said to an agent.
struct Composer: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if agent.state != .running, let note = pickUpNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(prompt, text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(12)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && agent.state != .running
    }

    private var prompt: String {
        agent.state == .running ? "Working…" : "Say something"
    }

    /// Saying what will happen, because sending to a stopped agent starts a runtime
    /// again and that takes a moment.
    private var pickUpNote: String? {
        switch agent.state {
        case .stopped, .finished: return "Sending will start \(runtimeName) again and carry on where this left off."
        case .archived: return "Sending will bring this back from the archive and carry on."
        case .waitingOnUser: return "This agent is waiting on the question above. Answer it, or stop the agent."
        case .running: return nil
        }
    }

    private var runtimeName: String {
        RuntimeCatalog.runtime(id: agent.runtimeID)?.name ?? agent.runtimeID
    }

    private func send() {
        guard canSend else { return }
        let outgoing = text
        text = ""
        Task { await model.send(outgoing) }
    }
}
