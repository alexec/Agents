import AgentsKitCore
import SwiftUI

/// The Mac-wide permission choice for runtimes that do not offer a mode of their own.
struct ClientPermissionCapsule: View {
    let runtimeID: String
    let mode: ClientPermissionMode
    let set: (ClientPermissionMode) -> Void

    private var runtimeName: String {
        RuntimeCatalog.runtime(id: runtimeID)?.name ?? runtimeID
    }

    private var title: String {
        ClientPermissionWords.title(mode)
    }

    var body: some View {
        SelectCapsule(name: "\(runtimeName) permission", title: title) { dismiss in
            ForEach([ClientPermissionMode.default, .alwaysApprove], id: \.self) { choice in
                SelectChoice(title: choice == .default ? "Default" : "Always-approve",
                             description: ClientPermissionWords.description(choice, runtimeName: runtimeName),
                             isChosen: choice == mode) {
                    set(choice)
                    dismiss()
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

}

enum ClientPermissionWords {
    static func title(_ mode: ClientPermissionMode) -> String {
        mode == .alwaysApprove ? "Always-approve" : "Default"
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
}
