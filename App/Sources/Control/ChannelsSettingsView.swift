import AgentsKitCore
import SwiftUI

/// Settings ▸ Channels (#1109): the places outside the app where agents' questions can go,
/// the control plane's and the same on every client. One row for each channel the control
/// plane knows, with its dot and status line; a row opens that channel's page. Slack (#1009)
/// is the first; the next channel adds a case here and a row on each page.
enum ChannelPage: Hashable {
    case overview, slack

    var title: String {
        switch self {
        case .overview: "Overview"
        case .slack: "Slack"
        }
    }
}

/// The pane's own pages, in a column beside the page (#1076), as Control plane lists its own.
struct ChannelPageList: View {
    let control: ControlSettingsModel
    @Binding var page: ChannelPage

    var body: some View {
        PageList {
            PageLine(title: ChannelPage.overview.title, lit: page == .overview, action: { page = .overview }) {
                EmptyView()
            }
            if let slack = control.slack {
                let status = ChannelStatus(slack)
                PageLine(title: ChannelPage.slack.title, lit: page == .slack,
                         label: "Slack, \(status.line)", action: { page = .slack }) {
                    ChannelDot(status: status)
                }
            }
        }
    }
}

struct ChannelsSettingsView: View {
    let control: ControlSettingsModel
    @Binding var page: ChannelPage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Text("Channels").appText(.reading).fontWeight(.semibold)
                    Text("›").foregroundStyle(.secondary)
                    Text(page.title).appText(.reading).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                if !control.isReachable {
                    Text("Can’t reach the control plane at \(control.whereItIs). What it last said is shown.")
                        .appText(.supporting).tinted(.attention)
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch page {
                case .overview: overview
                case .slack:
                    if let slack = control.slack {
                        ControlSlackCard(control: control, slack: slack)
                    } else {
                        none
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(20)
        }
        .task { await control.refreshChannels() }
    }

    @ViewBuilder private var overview: some View {
        Text("Answer agents’ questions from outside the app. Questions go to a channel when you are away from this Mac.")
            .appText(.supporting).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        // Nil from a control plane too old to know channels: no row at all.
        if let slack = control.slack {
            let status = ChannelStatus(slack)
            ControlCard {
                ControlRow(dot: status == .connected ? .online : .offline, title: "Slack", detail: status.line) {
                    Button("Show") { page = .slack }.buttonStyle(.link)
                }
            }
        } else {
            none
        }
    }

    private var none: some View {
        Text("This control plane has no channels.")
            .appText(.supporting).foregroundStyle(.secondary)
    }
}
