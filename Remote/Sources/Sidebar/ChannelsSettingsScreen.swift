import AgentsKitCore
import SwiftUI

/// Settings ▸ Channels (#1109): the places outside the app where agents' questions can go,
/// the control plane's and the same on every client. One row for each channel the control
/// plane knows, with its dot and status line; a row opens that channel's screen. Slack
/// (#1009) is the first; the next channel adds a row here.
struct ChannelsSettingsScreen: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        Form {
            Section {
                if let slack = model.slack {
                    let status = ChannelStatus(slack)
                    NavigationLink {
                        Form { SlackSettingsSection() }
                            .scrollContentBackground(.hidden)
                            .background(Paper.ground)
                            .navigationTitle("Slack")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        HStack(spacing: 10) {
                            ChannelDot(status: status)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Slack").appText(.supporting)
                                Text(status.line).appText(.fine).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Slack, \(status.line)")
                    }
                } else {
                    Text("This control plane has no channels.")
                        .appText(.supporting).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Answer agents’ questions from outside the app. Questions go to a channel when you are away from your Mac.")
            }
            .paperListRow()
        }
        .scrollContentBackground(.hidden)
        .background(Paper.ground)
        .navigationTitle("Channels")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadChannels() }
    }
}
