import AgentsKitCore
import SwiftUI

/// Settings ▸ Channels ▸ Slack (#1009, #1109): the control plane sends an agent's waiting
/// question to the person's Slack direct messages, and a reply there answers it. The tokens
/// go to the control plane and are never read back, shown or kept on this device.
struct SlackSettingsSection: View {
    @Environment(RemoteModel.self) private var model
    @State private var enabled = false
    @State private var memberID = ""
    /// Only what the person typed. Empty sends nothing for that token.
    @State private var appToken = ""
    @State private var botToken = ""
    @State private var saving = false
    @State private var problem: String?

    private static let setUpSteps = URL(string: "https://github.com/alexec/Agents/blob/main/docs/how-to/answer-questions-from-slack.md")!

    var body: some View {
        Section {
            if let slack = model.slack, !slack.available {
                Text(slack.detail ?? "Slack can’t run on this control plane.")
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
            } else {
                controls
            }
        } header: {
            Text("Slack")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Answer agents’ questions from Slack. Questions go to your direct messages when you are away from your Mac.")
                Link("Set-up steps", destination: Self.setUpSteps)
            }
        }
        .paperListRow()
        .task { await model.loadChannels() }
        .onChange(of: model.slack, initial: true) { _, slack in
            guard let slack else { return }
            enabled = slack.enabled
            memberID = slack.memberID
        }
    }

    @ViewBuilder private var controls: some View {
        let slack = model.slack
        Toggle("Send questions to Slack", isOn: $enabled)
            .appText(.supporting)
        TextField("Slack member ID", text: $memberID, prompt: Text("U…"))
            .autocorrectionDisabled()
            .appText(.supporting)
        tokenField("App token", prompt: "xapp-…", text: $appToken, isSet: slack?.appTokenSet ?? false)
        tokenField("Bot token", prompt: "xoxb-…", text: $botToken, isSet: slack?.botTokenSet ?? false)
        Button(saving ? "Saving…" : "Save") { Task { await save() } }
            .disabled(saving || slack == nil)
            .appText(.supporting)
        if let slack {
            Text(status(of: slack)).appText(.fine).foregroundStyle(.secondary)
        } else {
            Text("The control plane hasn’t answered yet.").appText(.fine).foregroundStyle(.secondary)
        }
        if let problem {
            Text(problem).appText(.fine).tinted(.failure)
        }
    }

    private func tokenField(_ title: String, prompt: String, text: Binding<String>, isSet: Bool) -> some View {
        LabeledContent {
            Text(isSet ? "Set" : "Not set").foregroundStyle(.secondary)
        } label: {
            SecureField(title, text: text, prompt: Text(prompt))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .appText(.supporting)
    }

    private func status(of slack: DaemonAPI.SlackState) -> String {
        switch slack.status {
        case DaemonAPI.SlackState.connected: "Connected"
        case DaemonAPI.SlackState.connecting: "Connecting…"
        case DaemonAPI.SlackState.failed: "Not connected: \(slack.detail ?? "Slack did not answer.")"
        default: slack.detail.map { "Not connected: \($0)" } ?? "Off"
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let request = DaemonAPI.SlackSet(
            enabled: enabled,
            memberID: memberID.trimmingCharacters(in: .whitespaces),
            appToken: appToken.isEmpty ? nil : appToken,
            botToken: botToken.isEmpty ? nil : botToken)
        problem = await model.setSlack(request)
        if problem == nil {
            appToken = ""
            botToken = ""
        }
    }
}
