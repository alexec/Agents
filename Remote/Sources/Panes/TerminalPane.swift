import AgentsKitCore
import SwiftTerm
import SwiftUI
import UIKit

/// The Terminal: the agent's shell, the one the Mac's pane shows, on the phone (034).
///
/// Not a second shell. The daemon holds one per agent, and this attaches to it with its
/// scrollback, as the Mac's pane does; a command started on either screen is running on
/// the other. Leaving the pane or the app lets go of nothing on the Mac (FR-023).
///
/// Nothing typed here reaches the agent, and nothing the agent runs appears here. This
/// is the person's shell.
struct TerminalPane: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent

    @State private var rows = 24
    @State private var cols = 60

    private var client: ShellClient { model.shellClient(for: agent.id) }

    var body: some View {
        let client = client
        VStack(spacing: 0) {
            if let problem = client.problem {
                Trouble(message: problem) {
                    await client.restart(rows: rows, cols: cols)
                }
            } else {
                if client.dropped > 0 {
                    Note("Earlier output was dropped.")
                }
                PhoneTerminalView(client: client, isEnabled: !model.isStale && client.state.isLive,
                                  onFocus: { model.isTyping = $0 }) { newRows, newCols in
                    rows = newRows
                    cols = newCols
                    Task { await client.resize(rows: newRows, cols: newCols) }
                }
                if !client.state.isLive {
                    ended(client)
                }
            }
        }
        .task(id: agent.id) { await client.attach(rows: rows, cols: cols) }
        .onChange(of: model.isStale) { _, stale in
            // A new connection knows nothing of this screen: attach again, which
            // replays what was printed while the phone was away.
            guard !stale else { client.lostConnection(); return }
            Task { await client.attach(rows: rows, cols: cols) }
        }
        .onDisappear {
            model.isTyping = false
            Task { await client.detach() }
        }
    }

    /// What the pane says once the shell is over. The screen stays as it was, so what it
    /// printed is still readable, and a new shell is one tap away (FR-022).
    private func ended(_ client: ShellClient) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(client.state.explanation ?? "The shell is no longer running.")
                .appText(.supporting)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Start again") {
                Task { await client.restart(rows: rows, cols: cols) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isStale)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Paper.well)
    }
}

/// SwiftTerm's iOS view, wired to a shell the Mac's daemon owns.
private struct PhoneTerminalView: UIViewRepresentable {
    let client: ShellClient
    /// Typing is refused while the Mac is not answering, or the shell has ended.
    let isEnabled: Bool
    let onFocus: (Bool) -> Void
    let onSize: (Int, Int) -> Void
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(client: client, onSize: onSize, onFocus: onFocus)
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = FocusReportingTerminal(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        view.terminalDelegate = context.coordinator
        view.onFocus = { context.coordinator.onFocus($0) }
        view.inputAccessoryView = ShellKeys(terminal: view)
        Self.paint(view)
        // Everything the daemon sends is fed here. The emulator is this side of the
        // connection and the daemon parses nothing.
        client.onOutput = { [weak view] data in
            view?.feed(byteArray: Array(data)[...])
        }
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        context.coordinator.client = client
        Self.paint(view)
        if !isEnabled, view.isFirstResponder { _ = view.resignFirstResponder() }
        (view as? FocusReportingTerminal)?.acceptsTyping = isEnabled
    }

    /// On paper, like the page around it: the ground, the ink, the caret and the
    /// selection. The sixteen ANSI colours are the program's to choose.
    private static func paint(_ view: TerminalView) {
        view.nativeBackgroundColor = .paperGround
        view.nativeForegroundColor = .paperInk
        view.caretColor = .paperInk
        view.selectedTextBackgroundColor = .paperSelection
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        var client: ShellClient
        let onSize: (Int, Int) -> Void
        let onFocus: (Bool) -> Void
        private var lastReported: (rows: Int, cols: Int) = (0, 0)

        init(client: ShellClient, onSize: @escaping (Int, Int) -> Void, onFocus: @escaping (Bool) -> Void) {
            self.client = client
            self.onSize = onSize
            self.onFocus = onFocus
        }

        // Bytes, not text: a keystroke is not always a character, and ^C goes this way,
        // through the line discipline, as in any terminal.
        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Data(data)
            Task { @MainActor in await self.client.send(bytes) }
        }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in
                guard (newRows, newCols) != (self.lastReported.rows, self.lastReported.cols) else { return }
                self.lastReported = (newRows, newCols)
                self.onSize(newRows, newCols)
            }
        }

        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        nonisolated func bell(source: TerminalView) {}
        nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        nonisolated func clipboardCopy(source: TerminalView, content: Data) {
            let text = String(decoding: content, as: UTF8.self)
            Task { @MainActor in UIPasteboard.general.string = text }
        }

        nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            // A link in a terminal is the person's to follow, in their own browser.
            Task { @MainActor in
                guard let url = URL(string: link), url.scheme == "http" || url.scheme == "https" else { return }
                await UIApplication.shared.open(url)
            }
        }
    }
}

/// The terminal, saying when it has the keyboard, and refusing it while typing would
/// reach nobody.
private final class FocusReportingTerminal: TerminalView {
    var onFocus: ((Bool) -> Void)?
    var acceptsTyping = true

    override var canBecomeFirstResponder: Bool { acceptsTyping && super.canBecomeFirstResponder }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocus?(false) }
        return resigned
    }
}

/// A quiet line above the screen. Not an error, just something worth knowing.
private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .appText(.fine)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
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
                .accessibilityHidden(true)
            Text(message)
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again") { Task { await retry() } }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
