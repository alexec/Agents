import AgentsKitCore
import SwiftUI

/// One agent's command sandbox, beside its mode (064, FR-004, FR-010): the state it runs
/// under, and, where the runtime has a route, a menu to set this agent's own choice.
/// A runtime with none shows its state alone, with the reason as the tooltip.
struct SandboxCapsule: View {
    let runtimeID: String
    /// This agent's own choice; nil follows the runtime's default.
    let override: SandboxChoice?
    let runtimeDefault: SandboxChoice
    /// Codex's current mode, which is its sandbox.
    var codexMode: String?
    /// Whether a turn is running, so the menu can say when a change applies (FR-012).
    var isWorking = false
    let choose: (SandboxChoice?) -> Void

    var body: some View {
        let choices = SandboxCatalog.choices(for: runtimeID)
        let words = SandboxWords.state(SandboxCatalog.state(runtimeID: runtimeID,
                                                           choice: override ?? runtimeDefault,
                                                           codexMode: codexMode))
        if choices.isEmpty {
            Text(words)
                .appText(.fine)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, TouchTarget.capsuleVertical)
                .fixedSize()
                .help(SandboxCatalog.entry(for: runtimeID)?.why ?? words)
        } else {
            SelectCapsule(name: "Command sandbox", title: words) { dismiss in
                SelectChoice(title: SandboxWords.override(nil, runtimeDefault: runtimeDefault, runtimeID: runtimeID),
                             description: nil, isChosen: override == nil) {
                    choose(nil)
                    dismiss()
                }
                ForEach(choices, id: \.self) { choice in
                    SelectChoice(title: SandboxWords.choice(choice, runtimeID: runtimeID),
                                 description: description(for: choice),
                                 isChosen: override == choice) {
                        choose(choice)
                        dismiss()
                    }
                }
            }
        }
    }

    private func description(for choice: SandboxChoice) -> String? {
        let name = RuntimeCatalog.runtime(id: runtimeID)?.name ?? runtimeID
        let what = SandboxWords.explanation(choice, runtimeID: runtimeID, name: name)
        return isWorking ? "\(what) \(SandboxWords.appliesNextTurn)" : what
    }
}
