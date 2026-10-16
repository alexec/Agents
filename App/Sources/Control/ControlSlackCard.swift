import AgentsKitCore
import SwiftUI

/// Settings ▸ Control plane ▸ Overview ▸ Slack (#1009): answer an agent's waiting question
/// from Slack. The control plane holds the tokens. The token fields start empty, are never
/// filled from it, and are cleared once saved.
struct ControlSlackCard: View {
    let control: ControlSettingsModel
    let slack: DaemonAPI.SlackState

    @State private var enabled = false
    @State private var memberID = ""
    @State private var appToken = ""
    @State private var botToken = ""
    /// True once the person changed the switch or the member ID, so news from the control
    /// plane does not write over what they typed.
    @State private var edited = false
    @State private var saving = false
    @State private var refusal: String?

    static let setUpSteps = URL(string: "https://github.com/alexec/Agents/blob/main/docs/how-to/answer-questions-from-slack.md")!

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Answer agents’ questions from Slack. Questions go to your direct messages when you are away from this Mac.")
                    .appText(.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Set-up steps", destination: Self.setUpSteps).appText(.supporting)
            }
            if slack.available {
                ControlCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Send questions to Slack", isOn: Binding(
                            get: { enabled },
                            set: { enabled = $0; edited = true }))
                        TextField("Your Slack member ID", text: Binding(
                            get: { memberID },
                            set: { memberID = $0; edited = true }), prompt: Text("U…"))
                        tokenRow("App token", prompt: "xapp-…", text: $appToken, isSet: slack.appTokenSet)
                        tokenRow("Bot token", prompt: "xoxb-…", text: $botToken, isSet: slack.botTokenSet)
                        HStack(spacing: 10) {
                            Button("Save") { save() }
                                .buttonStyle(.paper)
                                .disabled(saving)
                            Text(statusLine).appText(.supporting).foregroundStyle(.secondary)
                        }
                        if let refusal {
                            Text(refusal).appText(.supporting).tinted(.failure)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            } else {
                Text(slack.detail ?? "Slack can’t run on this control plane.")
                    .appText(.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { take(slack) }
        .onChange(of: slack) { _, now in if !edited { take(now) } }
    }

    private func tokenRow(_ title: String, prompt: String, text: Binding<String>, isSet: Bool) -> some View {
        HStack(spacing: 10) {
            SecureField(title, text: text, prompt: Text(prompt))
            Text(isSet ? "Set" : "Not set").appText(.supporting).foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .leading)
        }
    }

    private var statusLine: String {
        switch slack.status {
        case DaemonAPI.SlackState.connected: "Connected"
        case DaemonAPI.SlackState.connecting: "Connecting…"
        case DaemonAPI.SlackState.failed: "Not connected: \(slack.detail ?? "no reason given")"
        default: "Off"
        }
    }

    private func take(_ state: DaemonAPI.SlackState) {
        enabled = state.enabled
        memberID = state.memberID
    }

    private func save() {
        saving = true
        // A token field the person left empty is not sent, so the one already set stays.
        let app = appToken.isEmpty ? nil : appToken
        let bot = botToken.isEmpty ? nil : botToken
        Task {
            refusal = await control.saveSlack(enabled: enabled, memberID: memberID.trimmingCharacters(in: .whitespaces),
                                              appToken: app, botToken: bot)
            if refusal == nil {
                appToken = ""
                botToken = ""
                edited = false
                if let now = control.slack { take(now) }
            }
            saving = false
        }
    }
}
