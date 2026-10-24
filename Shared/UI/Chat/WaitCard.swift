import AgentsKitCore
import SwiftUI

/// What the open agent is waiting for (042), as a card at the end of the chat (#1995):
/// "◷ Waiting for “Fix login” to finish · since 14:02 · until 15:00", with **Stop Waiting**.
/// It was a capsule over the prompt, with a line saying that sending cancels the wait; a
/// prompt ends a wait as it does everywhere else, so that line went.
///
/// The question cards' shape, under them, since an agent waiting on an event is very like
/// one waiting for an answer. Not tinted: nothing has gone wrong, and the chat is already
/// under Waiting. One view for both apps; the web page's is `WaitCard` in `Chat.tsx`. The
/// Mac and the Remote open Events, Waiting now at its top, from it (#2083); the Remote not
/// from a chat in a scene of its own.
struct WaitCard: View {
    let status: WaitStatus
    let eventWait: EventWait?
    let isLineWait: Bool
    var open: (() -> Void)?
    let stop: () async -> Void
    var isDisabled = false

    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let eventWait, eventWait.isOpen, !isLineWait {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    eventContent(eventWait, now: context.date)
                }
            } else {
                Text(status.line)
                    .appText(.reading).fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Spacer()
                if let open {
                    Button("Show in Events", action: open)
                        .buttonStyle(.paper)
                }
                if status.cancellable {
                    Button("Stop Waiting") {
                        busy = true
                        Task {
                            await stop()
                            busy = false
                        }
                    }
                    .buttonStyle(.paper)
                    .help("Stop waiting. Nothing will start it again for this wait.")
                    .disabled(busy || isDisabled)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func eventContent(_ wait: EventWait, now: Date) -> some View {
        let total = wait.deadline.map { max(1, Int(ceil($0.timeIntervalSince(wait.since) / 60))) }
        let elapsed = max(0, Int(now.timeIntervalSince(wait.since) / 60))
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.blue)
                Text("Waiting for event").fontWeight(.semibold)
                Spacer(minLength: 6)
                Text(total.map { "\(elapsed) / \($0) min" } ?? "\(elapsed) min")
                    .appText(.fine).foregroundStyle(.secondary).monospacedDigit()
            }
            ForEach(Array(wait.patterns.enumerated()), id: \.offset) { _, pattern in
                let server = wait.serverEvents?.first { $0.trigger.event == pattern.name }
                let source = server.map { $0.servers.map(\.capitalized).joined(separator: " or ") }
                    .flatMap { $0.isEmpty ? nil : $0 } ?? Self.sourceName(pattern.name)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: server == nil ? "app" : "puzzlepiece.extension")
                            .foregroundStyle(.secondary)
                        Text(source).foregroundStyle(.secondary)
                        Text("·").foregroundStyle(.tertiary)
                        Text(pattern.name).fontWeight(.medium)
                    }
                    let filters = server.map { $0.trigger.arguments.sorted { $0.key < $1.key }.map { "\($0.key) \(Self.valueWords($0.value))" } }
                        ?? pattern.filters.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
                    if !filters.isEmpty {
                        Text(filters.joined(separator: " · ")).appText(.fine).foregroundStyle(.secondary)
                            .padding(.leading, 22)
                    }
                }
                .appText(.fine)
            }
            if let deadline = wait.deadline {
                ProgressView(value: min(1, max(0, now.timeIntervalSince(wait.since) / deadline.timeIntervalSince(wait.since))))
                    .tint(.blue)
                    .controlSize(.mini)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func sourceName(_ event: String) -> String {
        switch event.split(separator: ".").first.map(String.init) {
        case "mac", "machine", "person", "system", "cost", "lease": "This Mac"
        case "workflow": "Workflows"
        case "branch": "Branches"
        case "dropbox": "Drop box"
        default: "Agents"
        }
    }

    private static func valueWords(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): text
        case .int(let number): String(number)
        case .double(let number): String(number)
        case .bool(let flag): String(flag)
        case .null: "null"
        case .array, .object: String(describing: value)
        }
    }
}
