import AgentsKitCore
import SwiftUI

/// What the open agent is waiting for (042), as a card at the end of the chat (#1995):
/// "◷ Waiting for “Fix login” to finish · since 14:02 · until 15:00", with **Carry On**
/// and **End Wait** (#3052, #3152). It was a capsule over the prompt, with a line saying
/// that sending cancels the wait; a prompt ends a wait as it does everywhere else, so that
/// line went. Carry On sends that prompt itself (`EventWait.carryOnPrompt`), carrying the
/// agent on now without the event, as the block card's Carry On does; End Wait ends the
/// wait with nothing to start it again, the same whether the agent's call is still open
/// or not, and on iOS asks first (no hover there to say what it does).
///
/// The question cards' shape, under them, since an agent waiting on an event is very like
/// one waiting for an answer. Not tinted: nothing has gone wrong, and the chat is already
/// under Waiting. A wait only the person can settle (#3051) is the exception (#3147): its
/// session is under Needs you, so the card is tinted as a question is, heads with what it
/// asks of them ("Review requested: alexec/Agents#123"), and opens the PR or issue as its
/// main action. One view for both apps; the web page's is `WaitCard` in `Chat.tsx`.
struct WaitCard: View {
    /// The words both wait cards use (#3152), the web page's too.
    static let carryOn = "Carry On"
    static let carryOnHelp = "Carry on now, without waiting any longer."
    static let endWait = "End Wait"
    static let endWaitHelp = "End this wait. Nothing will start the agent again for it."

    let status: WaitStatus
    let eventWait: EventWait?
    let isLineWait: Bool
    /// `AgentsModel.waitEventLines`: its events in words, sessions by their titles (#2747).
    var lines: [WaitEventLine] = []
    let continueNow: () async -> Void
    let stop: () async -> Void
    var isDisabled = false

    @State private var busy = false
    @State private var confirmingEnd = false

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
                if let url = personURL {
                    Link("Open", destination: url)
                        .buttonStyle(.paperProminent)
                        .help("Open \(url.absoluteString) in the browser.")
                }
                if status.cancellable {
                    Button(Self.carryOn) {
                        busy = true
                        Task {
                            await continueNow()
                            busy = false
                        }
                    }
                    .buttonStyle(.paper)
                    .help(Self.carryOnHelp)
                    .disabled(busy || isDisabled)
                    Button(Self.endWait, role: .destructive) {
                        #if os(iOS)
                        confirmingEnd = true
                        #else
                        end()
                        #endif
                    }
                    .buttonStyle(.paper)
                    .tinted(.failure)
                    .help(Self.endWaitHelp)
                    .disabled(busy || isDisabled)
                }
            }
        }
        .confirmationDialog("End this wait?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button(Self.endWait, role: .destructive) { end() }
        } message: {
            Text("Nothing will start the agent again for it. Carry On starts it now instead.")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((personLine == nil ? nil : StateTint.attention.color?.opacity(0.07)) ?? .clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(((personLine == nil ? nil : StateTint.attention.color) ?? .secondary).opacity(0.25)))
        .accessibilityElement(children: .contain)
    }

    /// What a wait for the person asks of them (`EventWait.personLine`, #3147).
    private var personLine: String? { isLineWait ? nil : eventWait?.personLine }
    private var personURL: URL? { isLineWait ? nil : eventWait?.personURL }

    private func end() {
        busy = true
        Task {
            await stop()
            busy = false
        }
    }

    @ViewBuilder
    private func eventContent(_ wait: EventWait, now: Date) -> some View {
        let total = wait.deadline.map { max(1, Int(ceil($0.timeIntervalSince(wait.since) / 60))) }
        let elapsed = max(0, Int(now.timeIntervalSince(wait.since) / 60))
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                if let personLine {
                    // Needs you's mark and words, as the session's row has them (#3147).
                    Image(systemName: StatusShape.needsYou.symbol ?? "exclamationmark.circle.fill")
                        .tinted(.attention)
                        .accessibilityHidden(true)
                    Text(personLine).fontWeight(.semibold).tinted(.attention)
                } else {
                    // The waiting mark's beacon, breathing as it does everywhere else (#2657).
                    WaitingBeacon(size: 14)
                    Text("Waiting for event").fontWeight(.semibold)
                }
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
/// head with Carry on. Carry On carries the agent on now, as Carry On does on the wait on
/// events (#3152). The web page's is `BlockWaitCard` in `Chat.tsx`.
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
                Button(WaitCard.carryOn) {
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
