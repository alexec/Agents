import AgentsKitCore
import SwiftUI

/// Find in Chat (#1532): a field over the open chat that finds what was said in it, prompts
/// and replies, and goes from one match to the next. The host searches the whole transcript
/// (`agents/find`); going to a match brings its turn into the chat first.
///
/// Starts at the newest match. Return and ↑ go back through the chat, ⇧Return and ↓ come
/// forward, Escape closes it.
struct ChatFindBar: View {
    let agentID: UUID
    let search: @MainActor (String) async -> DaemonAPI.FindResult?
    let go: @MainActor (DaemonAPI.FindMatch) async -> Void
    let close: () -> Void

    @State private var text = ""
    @State private var result: DaemonAPI.FindResult?
    /// The match on show, by its place in `result.matches`.
    @State private var at: Int?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("Find in Chat", text: $text)
                .textFieldStyle(.plain)
                .appText(.supporting)
                .focused($focused)
                .onSubmit { step(back: true) }
                .onKeyPress(.upArrow) { step(back: true); return .handled }
                .onKeyPress(.downArrow) { step(back: false); return .handled }
                .onKeyPress(.escape) { close(); return .handled }
            if let words = count {
                Text(words)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
            Button { step(back: true) } label: { Image(systemName: "chevron.up") }
                .help("Earlier match")
                .accessibilityLabel("Earlier match")
                .disabled((at ?? 0) == 0)
            Button { step(back: false) } label: { Image(systemName: "chevron.down") }
                .help("Later match")
                .accessibilityLabel("Later match")
                .disabled(at.map { $0 >= (result?.matches.count ?? 0) - 1 } ?? true)
            Button("Done", action: close)
                .appText(.supporting)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .paperWell(in: Capsule())
        .chatColumn()
        .padding(.vertical, 6)
        .onAppear { focused = true }
        // A pause in the typing, then the host is asked; a newer word cancels the ask.
        .task(id: text) {
            let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else {
                result = nil
                at = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let found = await search(words), !Task.isCancelled else { return }
            result = found
            at = found.matches.isEmpty ? nil : found.matches.count - 1
            if let at { await go(found.matches[at]) }
        }
        .onChange(of: agentID) { close() }
    }

    /// "3 of 12", "No matches", or nothing before anything is typed. "12+" when older
    /// matches were left out.
    private var count: String? {
        guard let result else { return nil }
        guard let at else { return "No matches" }
        return "\(at + 1) of \(result.matches.count)\(result.more ? "+" : "")"
    }

    private func step(back: Bool) {
        guard let result, let at else { return }
        let next = back ? at - 1 : at + 1
        guard result.matches.indices.contains(next) else { return }
        self.at = next
        Task { await go(result.matches[next]) }
    }
}
