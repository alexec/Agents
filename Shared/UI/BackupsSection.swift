import AgentsKitCore
import SwiftUI

/// Settings ▸ Backups (#1810): how often this machine backs up its agents and transcripts,
/// how many backups it keeps, Back Up Now, and Restore for each backup in the folder, this
/// machine's or another's. The Mac's Settings window and the Remote's Settings screen draw
/// the same section; the web page draws the same in Web/src/views/Settings.tsx.
///
/// What it shows is what the host last said; each change goes through the host and comes
/// back. The restore being confirmed is held here, apart from the model, so a
/// `backups/changed` cannot close the dialog under the person (#101).
struct BackupsSection: View {
    let state: DaemonAPI.BackupState
    let configure: (DaemonAPI.BackupSettings) async throws -> Void
    let make: () async throws -> Void
    let restore: (DaemonAPI.Backup) async throws -> DaemonAPI.BackupRestoreResult
    /// The Mac's folder picker; nil where the folder is only shown.
    var chooseFolder: (() -> Void)?

    @State private var confirming: DaemonAPI.Backup?
    @State private var said: String?

    var body: some View {
        Section {
            Picker("Back up", selection: binding(\.every)) {
                ForEach(DaemonAPI.BackupEvery.allCases, id: \.self) { every in
                    Text(Self.everyLabel(every)).tag(every)
                }
            }
            Picker("Keep", selection: binding(\.keep)) {
                ForEach(1...10, id: \.self) { n in
                    Text(n == 1 ? "1 backup" : "\(n) backups").tag(n)
                }
            }
            LabeledContent("Folder") {
                HStack {
                    Text(state.folder)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if let chooseFolder {
                        Button("Choose…", action: chooseFolder)
                    }
                }
            }
            Button(state.making ? "Backing Up…" : "Back Up Now") {
                run { try await make() }
            }
            .disabled(state.making)
            ForEach(state.backups) { backup in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(backup.madeAt, format: .dateTime.day().month().year().hour().minute())
                        Text(Self.detail(backup))
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore…") { confirming = backup }
                }
            }
        } header: {
            Text("Backups")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let error = said ?? state.lastError {
                    Text(error)
                }
                Text("A backup holds this machine's agents, their conversations, and its usage and time history. "
                     + "It never holds a sign-in or a secret. Restore brings a backup's agents back archived; "
                     + "one this machine has already is left as it is. An agent from another machine is shown, never run.")
            }
            .appText(.fine)
            .foregroundStyle(.secondary)
        }
        .paperListRow()
        .confirmationDialog(confirming.map(Self.confirmTitle) ?? "",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { backup in
            Button("Restore") {
                run { said = Self.restored(try await restore(backup)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its agents come back archived. Nothing on this machine is changed or deleted.")
        }
    }

    /// One of the settings, read from the host's state and changed through it.
    private func binding<Value>(_ key: WritableKeyPath<DaemonAPI.BackupSettings, Value>) -> Binding<Value> {
        Binding(get: { state.settings[keyPath: key] }, set: { value in
            var settings = state.settings
            settings[keyPath: key] = value
            run { try await configure(settings) }
        })
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            said = nil
            do { try await work() } catch let error as JSONRPCError {
                said = error.message
            } catch {
                said = "That did not work: \(error.localizedDescription)"
            }
        }
    }

    static func everyLabel(_ every: DaemonAPI.BackupEvery) -> String {
        switch every {
        case .off: "Never"
        case .daily: "Every day"
        case .weekly: "Every week"
        }
    }

    static func detail(_ backup: DaemonAPI.Backup) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(backup.bytes), countStyle: .file)
        let agents = backup.agents == 1 ? "1 agent" : "\(backup.agents) agents"
        return [backup.thisMachine ? "This machine" : backup.machine, agents, size].joined(separator: " · ")
    }

    static func confirmTitle(_ backup: DaemonAPI.Backup) -> String {
        backup.thisMachine ? "Restore this backup?" : "Restore the backup of \(backup.machine)?"
    }

    static func restored(_ result: DaemonAPI.BackupRestoreResult) -> String {
        let back = result.restored == 1 ? "1 agent" : "\(result.restored) agents"
        let here = result.skipped == 0 ? "" : result.skipped == 1 ? " 1 was here already." : " \(result.skipped) were here already."
        return "Restored \(back), archived.\(here)"
    }
}
