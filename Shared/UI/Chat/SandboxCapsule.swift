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
    /// What its latest start ran under (FR-010), when that is still what it would ask for.
    var effective: EffectiveSandbox?
    /// Whether a turn is running, so the menu can say when a change applies (FR-012).
    var isWorking = false
    /// The organisation's mark while its policy requires the sandbox (#998): only On is in force.
    var setBy: DaemonAPI.PolicySetBy?
    let choose: (SandboxChoice?) -> Void

    var body: some View {
        let choices = SandboxCatalog.choices(for: runtimeID)
        let asked = override ?? runtimeDefault
        // The start's own record while it still stands: a capped helper says so. A choice
        // changed since shows what the next turn will be.
        let standing = effective.flatMap { $0.requested == asked ? $0 : nil }
        let state = SandboxWords.state(standing?.state
            ?? SandboxCatalog.state(runtimeID: runtimeID, choice: asked, codexMode: codexMode))
        if choices.isEmpty {
            // A runtime that cannot change its sandbox: its fixed value, and why (#2658).
            let fixed: SandboxChoice = SandboxCatalog.state(runtimeID: runtimeID, choice: .runtime, codexMode: nil) == .none ? .off : .runtime
            Text(LevelWords.sandbox(fixed))
                .appText(.fine)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, TouchTarget.capsuleVertical)
                .fixedSize()
                .help(setBy.map(OrgPolicyWords.line) ?? SandboxCatalog.entry(for: runtimeID)?.why ?? state)
        } else {
            // The pill says the value; the menu marks the one Settings gives (#2658).
            SelectCapsule(name: standing?.reason.map { "\(LevelWords.sandboxField): \($0)" } ?? "\(LevelWords.sandboxField): \(state)",
                          title: SandboxWords.override(override, runtimeDefault: runtimeDefault, runtimeID: runtimeID)) { dismiss in
                SelectGroupHeading(title: LevelWords.sandboxField)
                ForEach(choices, id: \.self) { choice in
                    SelectChoice(title: SandboxWords.choice(choice, runtimeID: runtimeID),
                                 description: description(for: choice),
                                 isChosen: asked == choice,
                                 setBy: choice == .on ? nil : setBy,
                                 mark: override == nil && choice == runtimeDefault ? LevelWords.followsSettings : nil) {
                        // The value Settings gives, chosen again, follows Settings still.
                        choose(override == nil && choice == runtimeDefault ? nil : choice)
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
