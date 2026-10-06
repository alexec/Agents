import AgentsKitCore
import SwiftUI

/// "Gemini on devbox needs a key" (043, contracts/ui.md § 3; Gemini's alone since 056): asked
/// before a server agent starts, rather than starting one that will fail. The window keeps the
/// key as Settings does; the Remote lends it on its own connection and keeps it nowhere (#344).
/// Either way the start goes ahead.
struct TokenAskCard: View {
    let ask: TokenAsk
    /// The pasted key, already checked for its kind: the app keeps or lends it, then
    /// answers the ask.
    let save: @MainActor (Secret) async -> Void
    let cancel: @MainActor () -> Void
    @State private var text = ""
    @State private var notACredential = false
    @State private var saving = false
    @FocusState private var focused: Bool

    private var name: String { RuntimeCatalog.runtime(id: ask.runtimeID)?.name ?? ask.runtimeID }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(name) on \(ask.label) needs a key").appText(.reading).fontWeight(.semibold)
            Text("\(ask.label) has no \(name) sign-in of its own. \(ask.keeping)")
                .appText(.fine).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Paste a \(name) key", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(submit)
            if notACredential {
                Text(CredentialKind.pasteRefusal(for: ask.runtimeID))
                    .appText(.fine).tinted(.failure)
            }
            Text(ask.whereToGet)
                .appText(.fine).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(ask.action, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.isEmpty || saving)
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 440)
        #endif
        .onAppear { focused = true }
    }

    private func submit() {
        guard let secret = Secret(text) else { notACredential = true; return }
        notACredential = false
        saving = true
        Task {
            await save(secret)
            saving = false
        }
    }
}

/// A server asked for a credential this client has none of (043, FR-015): asked of the
/// person in place, before the agent starts, and answered once. What happens to the key is
/// the client's, and its card says so.
struct TokenAsk: Identifiable {
    let id = UUID()
    let runtimeID: String
    let host: HostID
    let label: String
    /// What becomes of a pasted key, said after "… has no … sign-in of its own."
    let keeping: String
    /// Where to get one, under the field.
    let whereToGet: String
    /// The button that keeps or lends it, and starts.
    let action: String
    let answer: CheckedContinuation<Bool, Never>
}
