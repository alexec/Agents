import AgentsKitCore
import SwiftUI

/// One agent's answer to permission requests, for runtimes whose requests the app answers
/// (Cursor, Grok, OpenCode): its own choice, else the one Settings gives (#2658, FR-019).
///
/// It says its value alone, **Request cards** or **Yes to all**, as every pill does (#2658);
/// the menu's header names the field. Yes to all answers every request, so it asks once
/// more before it is set (#2746).
struct ClientPermissionCapsule: View {
    let runtimeID: String
    /// The agent's own choice; nil follows Settings.
    let own: ClientPermissionMode?
    /// The value Settings ▸ Agent Runtimes gives this runtime.
    let settings: ClientPermissionMode
    /// The agent's own choice, or nil to follow Settings again.
    let set: (ClientPermissionMode?) -> Void

    private var mode: ClientPermissionMode { own ?? settings }

    @State private var isConfirming = false

    private var runtimeName: String {
        RuntimeCatalog.runtime(id: runtimeID)?.name ?? runtimeID
    }

    var body: some View {
        SelectCapsule(name: ClientPermissionWords.name(runtimeName: runtimeName),
                      title: ClientPermissionWords.pill(mode)) { dismiss in
            // The choices stay laid out under the question, hidden: a phone's popover keeps
            // the size it opened at, and a taller second step there is cut short.
            ZStack(alignment: .topLeading) {
                choices(dismiss)
                    .opacity(isConfirming ? 0 : 1)
                    .accessibilityHidden(isConfirming)
                if isConfirming {
                    confirmation(dismiss)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            #if os(iOS)
            // A phone's popover measures its content at one line of text, then wraps it
            // narrower and cuts off the end: a set width gives it the height it needs.
            .frame(width: 320, alignment: .leading)
            #endif
        }
        // `.help` is not read on iOS: VoiceOver hears what the pill sets, then its value.
        .accessibilityLabel(ClientPermissionWords.name(runtimeName: runtimeName))
        .accessibilityValue(ClientPermissionWords.title(mode))
        .accessibilityHint(ClientPermissionWords.scope(runtimeName: runtimeName))
    }

    private func choices(_ dismiss: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach([ClientPermissionMode.default, .alwaysApprove], id: \.self) { choice in
                SelectChoice(title: ClientPermissionWords.title(choice),
                             description: ClientPermissionWords.description(choice, runtimeName: runtimeName),
                             isChosen: choice == mode,
                             mark: own == nil && choice == settings ? LevelWords.followsSettings : nil) {
                    if choice == .alwaysApprove, mode != .alwaysApprove {
                        isConfirming = true
                    } else {
                        // The value Settings gives, chosen again, follows Settings still.
                        set(own == nil && choice == settings ? nil : choice)
                        dismiss()
                    }
                }
            }
            Text(ClientPermissionWords.scope(runtimeName: runtimeName))
                .appText(.fine)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The second step in the same popover, not a dialog over it: a dialog shown while a
    /// popover closes is dropped on a phone.
    private func confirmation(_ dismiss: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ClientPermissionWords.confirmTitle(runtimeName: runtimeName))
                .appText(.fine)
                .fixedSize(horizontal: false, vertical: true)
            Text(ClientPermissionWords.confirmMessage(runtimeName: runtimeName))
                .appText(.fine)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") {
                    isConfirming = false
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer(minLength: 12)
                Button(ClientPermissionWords.confirmButton, role: .destructive) {
                    isConfirming = false
                    set(own == nil && settings == .alwaysApprove ? nil : .alwaysApprove)
                    dismiss()
                }
            }
            .appText(.fine)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Closed by a tap outside: the next open starts at the choices again.
        .onDisappear { isConfirming = false }
    }
}

enum ClientPermissionWords {
    /// In the words every runtime shares (#2658): **Request cards** or **Yes to all**.
    static func title(_ mode: ClientPermissionMode) -> String {
        LevelWords.requests(mode)
    }

    /// The closed pill: the value alone, as every pill says (#2658).
    static func pill(_ mode: ClientPermissionMode) -> String {
        title(mode)
    }

    static func name(runtimeName: String) -> String {
        "\(runtimeName) \(LevelWords.requestsField.lowercased())"
    }

    static func description(_ choice: ClientPermissionMode, runtimeName: String) -> String {
        LevelWords.meaning(requests: choice)
    }

    static func scope(runtimeName: String) -> String {
        "For this agent. Settings ▸ Agent Runtimes ▸ \(runtimeName) gives every new one its value."
    }

    static func confirmTitle(runtimeName: String) -> String {
        "Say yes to every permission request of this \(runtimeName) agent?"
    }

    static func confirmMessage(runtimeName: String) -> String {
        "It will not ask before it edits files or runs commands. Choose Request cards to make it ask again."
    }

    static let confirmButton = "Yes to All"
}
