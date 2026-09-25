import AgentsKit
import SwiftUI

/// "Claude on devbox needs a token" (043, contracts/ui.md § 3): asked before a server agent
/// starts, rather than starting one that will fail. Saving keeps the token as Settings
/// does, and the start goes ahead.
struct TokenAskCard: View {
    @Environment(AppModel.self) private var model
    let ask: TokenAsk
    @State private var text = ""
    @State private var notACredential = false
    @State private var saving = false
    @FocusState private var focused: Bool

    private var name: String { RuntimeCatalog.runtime(id: ask.runtimeID)?.name ?? ask.runtimeID }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(name) on \(ask.label) needs a token").appText(.reading).fontWeight(.semibold)
            Text("\(ask.label) has no \(name) sign-in of its own. Paste a token and Agents keeps it in this Mac’s Keychain, and lends it to \(ask.label) only while an agent runs there.")
                .appText(.fine).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Paste a \(name) token", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
            if notACredential {
                Text("That isn’t a Claude token or API key. They start sk-ant-oat or sk-ant-api.")
                    .appText(.fine).tinted(.failure)
            }
            Text("Make one with `claude setup-token` on this Mac.")
                .appText(.fine).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.finishTokenAsk(saved: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Save and Start", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.isEmpty || saving)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { focused = true }
    }

    private func save() {
        guard Secret(text) != nil else { notACredential = true; return }
        saving = true
        let pasted = text
        Task {
            let ok = await model.credentials.save(pasted, for: ask.runtimeID)
            saving = false
            model.finishTokenAsk(saved: ok)
        }
    }
}
