import AgentsKitCore
import SwiftUI

/// Notify me (#2034) on a project's Connectors page: each server's events that send the
/// person a notification, a switch each. The choices are the person's, kept on the host.
struct NotifyMeSection: View {
    @Environment(AppModel.self) private var model
    var project: ProjectKey

    @State private var list: DaemonAPI.NotifyList?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NotifyMeWords.heading).appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 10) {
                if let list, list.servers.isEmpty {
                    Text(NotifyMeWords.none).appText(.fine).foregroundStyle(.secondary)
                }
                ForEach(list?.servers ?? []) { server in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(server.title).appText(.supporting).fontWeight(.semibold)
                        ForEach(server.events) { event in
                            Toggle(event.title, isOn: Binding(get: { event.on }, set: { on in
                                Task { await set(server.server, event.event, on) }
                            }))
                            .toggleStyle(.checkbox)
                            .appText(.supporting)
                        }
                    }
                }
                Text(NotifyMeWords.note).appText(.fine).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let problem {
                    Text(problem).appText(.fine).tinted(.failure).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paperRaised(in: RoundedRectangle(cornerRadius: 10))
        }
        .task(id: project) { await load() }
    }

    private func load() async {
        switch await model.notifyList(project) {
        case .success(let fresh): list = fresh; problem = nil
        case .failure(let failure): problem = failure.words
        }
    }

    private func set(_ server: String, _ event: String, _ on: Bool) async {
        switch await model.notifySet(project, server: server, event: event, on: on) {
        case .success(let fresh): list = fresh; problem = nil
        case .failure(let failure): problem = failure.words
        }
    }
}
