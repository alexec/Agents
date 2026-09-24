import AgentsKit
import SwiftUI

/// A shell of the user's own, in the agent's folder.
///
/// The shell belongs to the daemon, not to this pane and not to this window. Moving to
/// another pane, switching agents, closing the window or quitting the app all leave it
/// running, and coming back finds it where it was with everything it printed in between
/// (FR-022, FR-026).
///
/// Nothing typed here reaches the agent, and nothing the agent runs appears here. This
/// is the user's shell (FR-025).
struct TerminalPane: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    let state: AgentPaneState

    @State private var client: ShellClient?
    @State private var rows = 24
    @State private var cols = 80

    var body: some View {
        VStack(spacing: 0) {
            if let client {
                if let problem = client.problem {
                    // A shell that would not start is about this pane, so it is said
                    // here rather than in an alert over the whole window (FR-024).
                    Trouble(message: problem) {
                        await client.restart(rows: rows, cols: cols)
                    }
                } else {
                    TerminalHostView(client: client) { newRows, newCols in
                        rows = newRows
                        cols = newCols
                        Task { await client.resize(rows: newRows, cols: newCols) }
                    }
                    if !client.state.isLive {
                        ended(client)
                    } else if client.dropped > 0 {
                        Note("The earlier part of this session is no longer held.")
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: agent.id) {
            let fresh = model.shellClient(for: agent.id)
            client = fresh
            await fresh.attach(rows: rows, cols: cols)
            state.isAttachedToShell = fresh.isAttached
        }
    }

    /// What the pane says once the shell is over. The screen stays as it was, so the
    /// output is still readable, and a new shell is one button away (FR-024, FR-028,
    /// FR-029).
    @ViewBuilder
    private func ended(_ client: ShellClient) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.secondary)
            Text(client.state.explanation ?? "The shell is no longer running.")
                .appText(.reading)
                .foregroundStyle(.secondary)
            Spacer()
            Button("New shell") {
                Task { await client.restart(rows: rows, cols: cols) }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary)
    }
}

/// A quiet line under the screen. Not an error, just something worth knowing.
private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .appText(.fine)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary)
    }
}

/// A shell that would not start at all, with the offer to try again.
private struct Trouble: View {
    let message: String
    let retry: () async -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .appText(.title)
                .foregroundStyle(.tertiary)
            Text(message)
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await retry() } }
                .controlSize(.small)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
