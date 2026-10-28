import AgentsKitCore
import SwiftUI

/// The Mac-wide permission choice for runtimes that do not offer a mode of their own.
///
/// It says what it sets ("Permissions: Default"), not the value alone, because it sits
/// beside the sandbox pill and is the only place to set it (#2559). Always-approve answers
/// every request for every agent of the runtime, so it asks once more before it is set (#2746).
struct ClientPermissionCapsule: View {
    let runtimeID: String
    let mode: ClientPermissionMode
    let set: (ClientPermissionMode) -> Void

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
                             isChosen: choice == mode) {
                    if choice == .alwaysApprove, mode != .alwaysApprove {
                        isConfirming = true
                    } else {
                        set(choice)
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
                    set(.alwaysApprove)
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
    static func title(_ mode: ClientPermissionMode) -> String {
        mode == .alwaysApprove ? "Always-approve" : "Default"
    }

    /// The closed pill: what it sets, then its value.
    static func pill(_ mode: ClientPermissionMode) -> String {
        "Permissions: \(title(mode))"
    }

    static func name(runtimeName: String) -> String {
        "\(runtimeName) permissions"
    }

    static func description(_ choice: ClientPermissionMode, runtimeName: String) -> String {
        switch choice {
        case .default:
            "Asks before \(runtimeName) does something that needs permission."
        case .alwaysApprove:
            "Answers every permission request for you. Questions that are not permission still wait."
        }
    }

    static func scope(runtimeName: String) -> String {
        "Applies to every \(runtimeName) agent, including workflows and server folders."
    }

    static func confirmTitle(runtimeName: String) -> String {
        "Always approve every \(runtimeName) permission request?"
    }

    static func confirmMessage(runtimeName: String) -> String {
        "No \(runtimeName) agent, workflow or server folder will ask before it edits files or runs commands. "
            + "Set Default to make them ask again."
    }

    static let confirmButton = "Always Approve"
}
