import Foundation

/// What the Mac and the phone say about a runtime's command sandbox (064, FR-014): one
/// place, so Settings, the prompt bar, the conversation and the card agree.
public enum SandboxWords {
    /// A choice, in the words every runtime shares (#2658): **Default sandbox**, **Runtime
    /// sandbox**, **No sandbox**. What it does on the runtime is its explanation.
    public static func choice(_ choice: SandboxChoice, runtimeID: String) -> String {
        LevelWords.sandbox(choice)
    }

    /// One agent's pill: its own choice, else the one Settings gives. In the menu, that one
    /// is marked **follows Settings** (`LevelWords.followsSettings`); there is no fourth value.
    public static func override(_ choice: SandboxChoice?, runtimeDefault: SandboxChoice, runtimeID: String) -> String {
        Self.choice(choice ?? runtimeDefault, runtimeID: runtimeID)
    }

    /// The state an agent's conversation shows (FR-010).
    public static func state(_ state: SandboxState) -> String {
        switch state {
        case .on: "Sandbox on"
        case .off: "Sandbox off"
        case .runtimeControlled: "Sandbox: runtime controlled"
        case .none: "No sandbox"
        }
    }

    /// One sentence under a runtime's Settings menu for what the selected choice does.
    public static func explanation(_ choice: SandboxChoice, runtimeID: String, name: String) -> String {
        let codex = runtimeID == RuntimeCatalog.codex.id
        switch choice {
        case .runtime:
            return codex
                ? "The mode decides: Full access has no sandbox, the other modes do."
                : "\(name)’s own settings decide. The app adds nothing."
        case .on:
            if codex { return "Commands can write only in the folder and cannot reach the network. The mode still decides when Codex asks." }
            if runtimeID == RuntimeCatalog.claude.id {
                return "Commands can write only in the folder, and Claude asks before they reach a new website. Its permission mode is a separate choice."
            }
            return "Commands can write only in the folder, its temporary folders and \(name)’s own folder. Its permission mode is a separate choice."
        case .off:
            return codex
                ? "Full access: commands run with your own access, and Codex stops asking for approval."
                : "Commands run with your own access. \(name) still asks as its permission mode says."
        }
    }

    public static let appliesNextTurn = "Applies from its next turn."
    public static let foldersStillApply = "The app’s own folder and tool rules still apply."

    // The card (FR-007).

    public static func cardTitle(_ name: String) -> String { "\(name)’s sandbox could not start" }

    public static func cardBody(runtimeID: String, name: String, hang: Bool) -> String {
        hang
            ? "\(name) did not answer when started. Its own sandbox is probably turned on, and it cannot start that way when the app runs it."
            : "\(name) could not isolate commands on this computer, so they did not run."
    }

    public static func cardOffer(runtimeID: String, name: String, afterTools: Bool) -> String {
        let access = runtimeID == RuntimeCatalog.codex.id
            ? "This sets this agent to Full access: Codex approval prompts are off too."
            : "This turns \(name)’s sandbox off for this agent only; its commands run with your own access."
        let resend = afterTools
            ? "Some commands already ran, so the app asks it to carry on rather than repeating your prompt."
            : "Your prompt is sent again."
        return "\(access) \(resend) \(foldersStillApply)"
    }

    public static func continuedNote(_ name: String) -> String { "Carried on without \(name)’s sandbox." }
    public static func keptStoppedNote(_ name: String) -> String { "Kept stopped rather than run without \(name)’s sandbox." }

    public static let continueWithout = "Continue without sandbox"
    public static let startWithout = "Start without sandbox"
    public static let keepStopped = "Keep stopped"
    public static let noRecovery = "The app cannot turn this runtime’s sandbox off."
}
