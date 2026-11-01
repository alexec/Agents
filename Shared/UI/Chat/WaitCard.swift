import AgentsKitCore
import SwiftUI

/// What the open agent is waiting for (042), as a card at the end of the chat (#1995):
/// "◷ Waiting for “Fix login” to finish · since 14:02 · until 15:00", with **Continue**
/// and **Cancel** (#3052). It was a capsule over the prompt, with a line saying that
/// sending cancels the wait; a prompt ends a wait as it does everywhere else, so that
/// line went. Continue sends that prompt itself (`EventWait.carryOnPrompt`), carrying
/// the agent on now without the event; Cancel ends the wait with nothing to start it
/// again. On a place in a line, Continue is "Carry on without build", and leaves the line
/// (#3151).
///
/// The question cards' shape, under them, since an agent waiting on an event is very like
/// one waiting for an answer. Not tinted: nothing has gone wrong, and the chat is already
/// under Waiting. One view for both apps; the web page's is `WaitCard` in `Chat.tsx`.
struct WaitCard: View {
    let status: WaitStatus
    let eventWait: EventWait?
    /// `AgentsModel.waitEventLines`: its events in words, sessions by their titles (#2747).
    var lines: [WaitEventLine] = []
    let continueNow: () async -> Void
    let stop: () async -> Void
    var isDisabled = false

    @State private var busy = false

    var body: some View {
        let line = eventWait?.lineResource
        VStack(alignment: .leading, spacing: 10) {
            if let eventWait, eventWait.isOpen, line == nil {
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
                if status.cancellable {
                    Button(line.map(EventWait.lineCarryOnLabel) ?? "Continue") {
                        busy = true
                        Task {
                            await continueNow()
                            busy = false
                        }
                    }
                    .buttonStyle(.paper)
                    .help(line.map { "Leave the line for \($0.key) and carry on now, without it." }
                        ?? "Carry on now, without waiting for the event.")
                    .disabled(busy || isDisabled)
                    Button("Cancel") {
                        busy = true
                        Task {
                            await stop()
                            busy = false
                        }
                    }
                    .buttonStyle(.paper)
                    .help("Cancel this wait. Nothing will start it again for this wait.")
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
                // The waiting mark's beacon, breathing as it does everywhere else (#2657).
                WaitingBeacon(size: 14)
                Text("Waiting for event").fontWeight(.semibold)
                Spacer(minLength: 6)
                Text(total.map { "\(elapsed) / \($0) min" } ?? "\(elapsed) min")
                    .appText(.fine).foregroundStyle(.secondary).monospacedDigit()
            }
            ForEach(lines) { line in
                eventLine(line)
                    .appText(.fine)
                    .fixedSize(horizontal: false, vertical: true)
                    // The events' own names, for whoever writes a wait or a workflow.
                    .help(line.events.joined(separator: ", "))
            }
            if let deadline = wait.deadline {
                ProgressView(value: min(1, max(0, now.timeIntervalSince(wait.since) / deadline.timeIntervalSince(wait.since))))
                    .tint(.blue)
                    .controlSize(.mini)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// One of the card's event lines (#2747): "GitHub · PR merged (repo alexec/Agents)",
    /// the parenthesised arguments a link to the PR or issue they name, when they name
    /// one (#3077).
    @ViewBuilder
    private func eventLine(_ line: WaitEventLine) -> some View {
        HStack(spacing: 5) {
            Text(line.source).foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Text(line.words).fontWeight(.medium)
            if !line.arguments.isEmpty {
                let words = "(\(line.arguments.joined(separator: ", ")))"
                if let url = line.url {
                    Link(destination: url) { Text(words).underline() }
                } else {
                    Text(words).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A wait on sessions or on a time (`wait_for_agents`, `check_again`), drawn as the wait on
/// events is (#2750): the same card at the foot of the chat, with what it waits on, when it
/// checks again as its deadline, and one way to stop it. It was a strip under the chat's
/// head with Carry on. Stop Waiting carries the agent on now, as Stop Waiting does to a
/// wait on events whose call is still open. The web page's is `BlockWaitCard` in `Chat.tsx`.
struct BlockWaitCard: View {
    let block: Block
    /// When it began to wait: its report's time.
    let since: Date
    /// `AgentsModel.blockLines`: any of or all of, one line a session, and when it checks again.
    let lines: [String]
    let stop: () async -> Void
    var help = "Stop waiting and carry on now"
    var isDisabled = false

    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: .now, by: 20)) { context in
                content(now: context.date)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Stop Waiting") {
                    busy = true
                    Task {
                        await stop()
                        busy = false
                    }
                }
                .buttonStyle(.paper)
                .help(help)
                .disabled(busy || isDisabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25)))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let deadline = block.checkAgainAt
        let total = deadline.map { max(1, Int(ceil($0.timeIntervalSince(since) / 60))) }
        let elapsed = max(0, Int(now.timeIntervalSince(since) / 60))
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                WaitingBeacon(size: 14)
                Text(block.cardTitle()).fontWeight(.semibold)
                Spacer(minLength: 6)
                Text(total.map { "\(elapsed) / \($0) min" } ?? "\(elapsed) min")
                    .appText(.fine).foregroundStyle(.secondary).monospacedDigit()
            }
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .appText(.fine)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let deadline, deadline > since {
                ProgressView(value: min(1, max(0, now.timeIntervalSince(since) / deadline.timeIntervalSince(since))))
                    .tint(.blue)
                    .controlSize(.mini)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
