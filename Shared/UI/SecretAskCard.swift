import AgentsKitCore
import SwiftUI

/// An agent's `ask_secret` (#2885), drawn by the window's `ElicitationView` and the Remote's
/// `ElicitationSheet` under their own "who asks" line: the secret's name, why, where to get
/// it, and a masked field. What is typed goes to the host, which saves it to the person's
/// secrets.env; the chat, the agent and every other client get the name only.
struct SecretAskCard: View {
    let secret: ElicitationRequest.Secret
    /// The agent's reason, the form's one field's title.
    let reason: String?
    /// Who keeps it: "your Mac", or the agent's server.
    let host: String
    /// An answer is on the way: the card is held until the daemon takes it down.
    let sending: Bool
    /// Save (with the value) or No thanks (nil).
    let send: @MainActor (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var typed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(secret.name).monospaced().fontWeight(.semibold)
            } icon: {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
            }
            .appText(.reading)
            .accessibilityLabel("Asks for the secret \(secret.name)")
            if let reason, !reason.isEmpty {
                Text(reason).appText(.reading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let url = secret.url.flatMap(URL.init(string:)) {
                Link(destination: url) {
                    Text("Get it at \(url.host() ?? url.absoluteString)")
                }
                .appText(.supporting)
            }
            SecureField("Paste \(secret.name)", text: $text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .focused($focused)
                .onSubmit(save)
                .disabled(sending)
            Text(Self.keeping(secret, on: host))
                .appText(.fine).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if sending { Telling(host: host) }
                Spacer(minLength: 0)
                // No Escape: in the chat, an Escape meant for something else would decline it.
                Button("No thanks") { send(nil) }
                    .buttonStyle(.paper)
                    .disabled(sending)
                Button("Save securely", action: save)
                    .buttonStyle(.paperProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(typed.isEmpty || sending)
            }
        }
        .onAppear { focused = true }
    }

    private func save() {
        guard !typed.isEmpty, !sending else { return }
        send(typed)
    }

    /// Under the field: where it goes, and that the agent never sees it.
    static func keeping(_ secret: ElicitationRequest.Secret, on host: String) -> String {
        let replaces = secret.isSet ? " It replaces the one saved there." : ""
        return "Saved to your secrets on \(host).\(replaces) The agent gets its name, never the value."
    }
}
