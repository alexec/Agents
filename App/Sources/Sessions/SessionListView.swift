import AgentsKit
import SwiftUI

/// What the runtime is holding that the app does not.
///
/// An agent is a thing the user owns, not a thing this app owns. A conversation started
/// from a terminal yesterday is theirs, and this is how they get it back.
struct SessionListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let runtimeID: String
    let cwd: URL

    @State private var sessions: [RuntimeSession] = []
    @State private var isLoading = true
    @State private var deleting: RuntimeSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Conversations in \(cwd.lastPathComponent)")
                .appText(.reading).fontWeight(.semibold)

            if isLoading {
                Text("Asking \(name)…").appText(.supporting).foregroundStyle(.secondary)
            } else if sessions.isEmpty {
                Text("\(name) is holding nothing here.")
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sessions) { session in
                            row(session)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.paper)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            sessions = await model.runtimeSessions(runtimeID: runtimeID, cwd: cwd)
            isLoading = false
        }
        .confirmationDialog("Delete this conversation?", isPresented: .init(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                guard let session = deleting else { return }
                Task {
                    await model.deleteRuntimeSession(runtimeID: runtimeID, sessionID: session.sessionID)
                    sessions.removeAll { $0.sessionID == session.sessionID }
                    deleting = nil
                }
            }
        } message: {
            Text("This removes it from \(name) as well as from here. It cannot be undone.")
        }
    }

    private var name: String { RuntimeCatalog.runtime(id: runtimeID)?.name ?? runtimeID }

    @ViewBuilder
    private func row(_ session: RuntimeSession) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title ?? session.sessionID)
                    .appText(.reading)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let updatedAt = session.updatedAt {
                        Text(updatedAt.formatted(.relative(presentation: .named)))
                    }
                    if session.isHeld {
                        Text("already here")
                    }
                }
                .appText(.fine)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            if !session.isHeld {
                Button("Pick up") {
                    Task {
                        await model.adopt(runtimeID: runtimeID, session: session)
                        dismiss()
                    }
                }
                .buttonStyle(.paper)
            }
            Button {
                deleting = session
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Delete this conversation from \(name)")
        }
        .padding(.vertical, 8)
    }
}
