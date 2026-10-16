import AgentsKitCore
import SwiftUI

/// Git access (#1122): which hosts use a Mac's git access, and for which git servers, each
/// taken back with Stop Lending. Shown only while there is one.
struct GitAccessSettingsSection: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        let lends = GitLendAsk.lends(in: model.controlHosts)
        if !lends.isEmpty {
            Section {
                ForEach(lends) { lend in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(lend.hostName) · \(lend.server)")
                            Text("Uses \(lend.lenderName)’s git access")
                                .appText(.supporting).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Stop Lending") {
                            Task { await model.lendGit(host: lend.host, from: lend.from, server: lend.server, allowed: false) }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Git access")
            } footer: {
                Text("A host asks the first time its git needs a Mac’s git access for a server. Nothing is kept on the host.")
            }
            .paperListRow()
        }
    }
}
