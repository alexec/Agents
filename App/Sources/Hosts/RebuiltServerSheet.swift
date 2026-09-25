import AgentsKit
import SwiftUI

/// "devbox has a new identity" (043, contracts/ui.md § 5): a known server whose key has
/// changed. Never connected to silently; the person compares the two fingerprints and says
/// whether it was rebuilt. Cancel is the default.
struct RebuiltServerSheet: View {
    @Environment(AppModel.self) private var model
    let host: HostID
    @State private var before: String?
    @State private var fetched: HostKeyCheck.Fetched?
    @State private var problem: String?
    @State private var working = false

    private var label: String { model.hosts.label(host) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(label) has a new identity").appText(.reading).fontWeight(.semibold)
            Text("This happens when a server is rebuilt. If you didn’t rebuild it, someone may be pretending to be it — cancel and check.")
                .appText(.fine).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Before").foregroundStyle(.secondary)
                    Text(before ?? model.hosts.host(host)?.trustedFingerprint ?? "—").appText(.code).textSelection(.enabled)
                }
                GridRow {
                    Text("Now").foregroundStyle(.secondary)
                    if let fetched {
                        Text(fetched.fingerprint).appText(.code).textSelection(.enabled)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .appText(.fine)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            if let problem {
                Text(problem).appText(.fine).tinted(.failure)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close() }
                    .keyboardShortcut(.defaultAction)
                Button("This server was rebuilt", role: .destructive) { rebuilt() }
                    .disabled(fetched == nil || working)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await look() }
    }

    private func look() async {
        guard let server = model.hosts.host(host) else { return }
        let ssh = HostSet.ssh(for: server, locations: .default)
        do {
            let resolved = try await HostKeyCheck.resolve(ssh)
            before = await HostKeyCheck.knownFingerprint(resolved)
            fetched = try await HostKeyCheck.fetch(ssh)
        } catch let problem as HostProblem {
            self.problem = problem.sentence(name: server.sshName, label: server.label)
        } catch {
            problem = "\(error)"
        }
    }

    private func rebuilt() {
        guard let fetched else { return }
        working = true
        Task {
            do {
                try await model.hosts.trustRebuilt(host, fetched)
                self.fetched = nil
                model.hosts.rebuiltAsk = nil
            } catch {
                problem = "\(error)"
                working = false
            }
        }
    }

    private func close() {
        if let fetched { HostKeyCheck.discard(fetched) }
        model.hosts.rebuiltAsk = nil
    }
}
