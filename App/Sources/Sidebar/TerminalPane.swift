import AgentsKitCore
import SwiftUI

/// Shells of the user's own, in the agent's folder, one per tab (055).
///
/// The shells belong to the daemon, not to this pane and not to this window. Moving to
/// another pane, switching agents, closing the window or quitting the app all leave them
/// running, and coming back finds them where they were with everything they printed in
/// between (FR-022, FR-026). Closing a tab is the one thing that ends a shell.
///
/// Nothing typed here reaches the agent, and nothing the agent runs appears here. These
/// are the user's shells (FR-025).
struct TerminalPane: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    let state: AgentPaneState

    var body: some View {
        VStack(spacing: 0) {
            ShellTabs(state: state, open: open, close: close)
            Divider()
            // Every tab's screen is built and the hidden ones kept alive, as the panes
            // are, so a tab comes back with its screen and scrollback as it was.
            ZStack {
                ForEach(state.shells, id: \.self) { shell in
                    ShellScreen(agent: agent, shell: shell, isFront: state.frontShell == shell,
                                wantsFocus: state.shellToFocus == shell,
                                focused: { if state.shellToFocus == shell { state.shellToFocus = nil } })
                        .opacity(state.frontShell == shell ? 1 : 0)
                        .allowsHitTesting(state.frontShell == shell)
                }
            }
        }
        .task(id: agent.id) {
            guard !state.shellsLoaded else { return }
            state.shellsLoaded = true
            guard let held = await model.shellNumbers(for: agent.id) else {
                state.canOpenMoreShells = false
                return
            }
            state.shells = held
            if !held.contains(state.frontShell) { state.frontShell = held.first ?? 0 }
        }
    }

    private func open() {
        let next = (state.shells.max() ?? -1) + 1
        state.shells.append(next)
        state.frontShell = next
        state.shellToFocus = next
    }

    private func close(_ shell: Int) {
        guard state.shells.count > 1, let index = state.shells.firstIndex(of: shell) else { return }
        state.shells.remove(at: index)
        if state.frontShell == shell {
            state.frontShell = state.shells[min(index, state.shells.count - 1)]
            state.shellToFocus = state.frontShell
        }
        Task { await model.closeShell(agentID: agent.id, shell: shell) }
    }
}

/// The row of tabs over the screen, with the button that opens another.
private struct ShellTabs: View {
    let state: AgentPaneState
    let open: () -> Void
    let close: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            // More tabs than fit scroll sideways, and the one on top is kept in view:
            // a tab just opened at the end of a narrow column is otherwise off the edge.
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(state.shells.enumerated()), id: \.element) { position, shell in
                            ShellTab(title: "Shell \(position + 1)",
                                     isFront: state.frontShell == shell,
                                     canClose: state.shells.count > 1,
                                     select: {
                                         state.frontShell = shell
                                         state.shellToFocus = shell
                                     },
                                     close: { close(shell) })
                            .id(shell)
                        }
                    }
                }
                .onChange(of: state.frontShell) { _, front in
                    withAnimation { reader.scrollTo(front) }
                }
            }
            Button(action: open) {
                Image(systemName: "plus")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("New shell")
            .disabled(!state.canOpenMoreShells)
            .help(state.canOpenMoreShells
                  ? "New shell"
                  : "This agent's machine runs an older helper that holds one shell per agent.")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// One tab. The whole tab is the button that brings it forward; the close mark shows
/// on the front tab and under the pointer, and only when there is another to fall
/// back to.
private struct ShellTab: View {
    let title: String
    let isFront: Bool
    let canClose: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                Text(title)
                    .appText(.supporting)
                    .foregroundStyle(isFront ? .primary : .secondary)
                if canClose {
                    // Room is kept for the mark whether or not it shows, so tabs do
                    // not shift under the pointer.
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .appText(.fine)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .opacity(isFront || isHovered ? 1 : 0)
                    .help("Close this shell")
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, canClose ? 6 : 10)
            .padding(.vertical, 4)
            .background(isFront ? Paper.wash : (isHovered ? Paper.well : .clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        // The mark is inside the tab's button, where accessibility cannot reach it on
        // its own, so closing is offered on the tab as well.
        .accessibilityAction(named: "Close") { if canClose { close() } }
    }
}

/// One shell's screen, and what it says when that shell will not start or has ended.
private struct ShellScreen: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    let shell: Int
    let isFront: Bool
    let wantsFocus: Bool
    let focused: () -> Void

    @State private var client: ShellClient?
    @State private var rows = 24
    @State private var cols = 80
    /// The folder `cd` was typed for from the strip, so the strip goes once it has done
    /// its job: the shell's own folder is not something the daemon can follow.
    @State private var cdTypedFor: URL?

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
                    TerminalHostView(client: client, wantsFocus: wantsFocus, focused: focused,
                                     isFront: isFront) { newRows, newCols in
                        rows = newRows
                        cols = newCols
                        Task { await client.resize(rows: newRows, cols: newCols) }
                    }
                    // A margin of the terminal's own ground, so the first column and
                    // the last line are not pressed against the pane's edges.
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Paper.ground)
                    if !client.state.isLive {
                        ended(client)
                    } else if let opened = client.folder, !sameFolder(opened, agent.cwd),
                              cdTypedFor.map({ !sameFolder($0, agent.cwd) }) ?? true {
                        moved(client, from: opened)
                    } else if client.dropped > 0 {
                        Note("The earlier part of this session is no longer held.")
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: agent.id) {
            let held = client ?? model.acquireShell(for: agent.id, shell: shell)
            client = held
            await held.attach(rows: rows, cols: cols)
        }
        .onDisappear {
            if let client { model.releaseShell(client) }
            client = nil
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
        .background(Paper.well)
    }

    /// The agent moved (053) while this shell went on in the folder it was started in.
    /// The shell is the person's and may be running something, so nothing ends it: the
    /// strip says where each of them is, and offers to type the `cd` for them.
    private func moved(_ client: ShellClient, from opened: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
            Text("This shell is in \(opened.lastPathComponent). The agent now works in \(agent.worktree?.name ?? agent.cwd.lastPathComponent).")
                .appText(.fine)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button("Type cd there") {
                let path = agent.cwd.path(percentEncoded: false).replacingOccurrences(of: "'", with: "'\\''")
                cdTypedFor = agent.cwd
                Task { await client.send(Data("cd '\(path)'\r".utf8)) }
            }
            .controlSize(.small)
            .help("Types cd \(agent.cwd.path(percentEncoded: false)) into this shell")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Paper.well)
    }

    private func sameFolder(_ one: URL, _ other: URL) -> Bool {
        one.resolvingSymlinksInPath().standardizedFileURL.path == other.resolvingSymlinksInPath().standardizedFileURL.path
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
            .background(Paper.well)
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
