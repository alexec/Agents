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
                TimelineView(.periodic(from: .now, by: 20)) { context in
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
                // The waiting mark's beacon in the same colour: one icon for waiting (#2657).
                Image(systemName: StatusShape.waitingSymbol).foregroundStyle(Paper.accent)
                Text("Waiting for event").fontWeight(.semibold)
                Spacer(minLength: 6)
                Text(total.map { "\(elapsed) / \($0) min" } ?? "\(elapsed) min")
                    .appText(.fine).foregroundStyle(.secondary).monospacedDigit()
            }
            ForEach(Self.eventLines(for: wait)) { line in
                HStack(spacing: 5) {
                    Text(line.source).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(line.events.joined(separator: ", ")).fontWeight(.medium)
                    if !line.arguments.isEmpty {
                        Text("(\(line.arguments.joined(separator: ", ")))").foregroundStyle(.secondary)
                    }
                }
                .appText(.fine)
                .fixedSize(horizontal: false, vertical: true)
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

    private static func eventLines(for wait: EventWait) -> [WaitEventSummary] {
        var lines: [WaitEventSummary] = []
        for pattern in wait.patterns {
            let server = wait.serverEvents?.first { $0.trigger.event == pattern.name }
            let names = server.map { $0.servers.isEmpty ? ($0.trigger.servers ?? []) : $0.servers } ?? []
            let source = if server == nil {
                sourceName(pattern.name)
            } else if names.isEmpty {
                "Connected tools"
            } else {
                names.map(serverName).joined(separator: " or ")
            }
            let arguments = server.map {
                $0.trigger.arguments.sorted { $0.key < $1.key }.map { "\($0.key) \(valueWords($0.value))" }
            } ?? pattern.filters.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.label)" }
            let id = source + "\u{0}" + arguments.joined(separator: "\u{0}")
            if let index = lines.firstIndex(where: { $0.id == id }) {
                if !lines[index].events.contains(pattern.name) { lines[index].events.append(pattern.name) }
            } else {
                lines.append(WaitEventSummary(id: id, source: source, events: [pattern.name], arguments: arguments))
            }
        }
        return lines
    }

    private static func serverName(_ name: String) -> String {
        switch name.lowercased() {
        case "github": "GitHub"
        case "gitlab": "GitLab"
        case "linear": "Linear"
        case "email": "Email"
        default: name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
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

private struct WaitEventSummary: Identifiable {
    let id: String
    let source: String
    var events: [String]
    let arguments: [String]
}
