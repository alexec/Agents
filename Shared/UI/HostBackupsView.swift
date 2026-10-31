import AgentsKitCore
import SwiftUI

/// One host's backups (#1815): the same `BackupsSection` as this Mac's, drawn for a server
/// and sent to that host with the same `backups/*` methods. The Mac opens it from a host's
/// menu in Settings ▸ Machines, the Remote from Settings ▸ Machines' Backups;
/// the web page draws the same in Web/src/views/Settings.tsx.
///
/// It holds the host's state itself, read when it opens and after each change. While a
/// backup is being made it reads again every few seconds, so the page shows when it ends:
/// the clients' models keep only the Mac's `backups/changed`.
struct HostBackupsView: View {
    let client: DaemonClient
    let hostName: String

    @State private var state: DaemonAPI.BackupState?
    @State private var failure: String?

    init(client: DaemonClient, hostName: String) {
        self.client = client
        self.hostName = hostName
    }

    var body: some View {
        Form {
            if let state {
                BackupsSection(state: state, configure: configure, make: make, restore: restore, title: "Backups of \(hostName)")
            } else if let failure {
                Text(failure).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .paperForm()
        .task { await read() }
        .task(id: state?.making == true) {
            while state?.making == true, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await read()
            }
        }
    }

    private func read() async {
        do {
            state = try await client.call(DaemonAPI.Method.backupsState, DaemonAPI.Empty(), returning: DaemonAPI.BackupState.self)
            failure = nil
        } catch let error as JSONRPCError {
            failure = error.message
        } catch {
            failure = "\(hostName) can’t be asked now: \(error.localizedDescription)"
        }
    }

    private func configure(_ settings: DaemonAPI.BackupSettings) async throws {
        state = try await client.call(DaemonAPI.Method.backupsConfigure, settings, returning: DaemonAPI.BackupState.self)
    }

    private func make() async throws {
        state = try await client.call(DaemonAPI.Method.backupsMake, DaemonAPI.BackupMakeRequest(),
                                      returning: DaemonAPI.BackupState.self)
    }

    private func restore(_ backup: DaemonAPI.Backup) async throws -> DaemonAPI.BackupRestoreResult {
        try await client.call(DaemonAPI.Method.backupsRestore, DaemonAPI.BackupRestoreRequest(id: backup.id),
                              returning: DaemonAPI.BackupRestoreResult.self)
    }
}
