import AgentsKitCore
import SwiftUI

/// One event, and what came of it (042 FR-026, FR-027; wireframes §1, §4).
///
/// One view for both apps, so the Mac's page and the phone's list say the same words.
/// The time, the sentence, then the name in small monospace with its scope — the name
/// is shown because it is what you would write in a workflow or a wait, and this list
/// is where people learn the names. What came of it is indented underneath, each
/// line starting ↳, and every agent in it is a way to that chat.
///
/// Nothing is tinted: an event is a fact, not a state (wireframes §5). "Refused by"
/// and "Could not wake" are words, not red — a refusal is the safety rules working.
///
/// What differs by app comes in as closures. `openAgent` is both apps'. `openWorkflow`
/// is only the Mac's: the phone has no workflow page, so there the name is plain text.
struct EventRow: View {
    let event: Event
    /// "This Mac", or the project's name.
    let scopeName: String
    var openAgent: ((UUID) -> Void)?
    var openWorkflow: ((URL, String) -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(LeaseWords.clock(event.at))
                .appText(.fine)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 38, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(event.sentence)
                        .appText(.reading)
                        .fixedSize(horizontal: false, vertical: true)
                    if event.count > 1 {
                        Text("×\(event.count)")
                            .appText(.fine)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(event.subject?.glyph ?? "·") \(event.name) · \(scopeName)")
                    .appText(.fine)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let message = event.message, !message.isEmpty {
                    Text("\u{201C}\(message)\u{201D}")
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(event.consequences.enumerated()), id: \.offset) { _, consequence in
                    ConsequenceLine(consequence: consequence, openAgent: openAgent, openWorkflow: openWorkflow)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// One thing the app did because of an event: ↳ *Woke* “Merge when green”.
private struct ConsequenceLine: View {
    let consequence: Consequence
    var openAgent: ((UUID) -> Void)?
    var openWorkflow: ((URL, String) -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\u{21B3}").foregroundStyle(.tertiary)
            Text(verb).italic().foregroundStyle(.secondary)
            target
            if let reason {
                Text("— \(reason)")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .appText(.supporting)
    }

    private var verb: String {
        switch consequence {
        case .woke: return "Woke"
        case .fired: return "Fired"
        case .refused: return "Refused by"
        case .couldNotWake: return "Could not wake"
        }
    }

    private var reason: String? {
        switch consequence {
        case .refused(_, _, let reason): return reason.message
        case .couldNotWake(_, _, let reason): return reason
        case .woke, .fired: return nil
        }
    }

    @ViewBuilder private var target: some View {
        switch consequence {
        case .woke(let agentID, let title), .couldNotWake(let agentID, let title, _):
            link(LeaseWords.agentName(title)) { openAgent.map { open in { open(agentID) } } }
        case .fired(let workflowID, let folder, let agentID):
            link(workflowID) { openWorkflow.map { open in { open(folder, workflowID) } } }
            if let agentID, let openAgent {
                Button("›") { openAgent(agentID) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open the agent it started")
            }
        case .refused(let workflowID, let folder, _):
            link(workflowID) { openWorkflow.map { open in { open(folder, workflowID) } } }
        }
    }

    @ViewBuilder
    private func link(_ text: String, action: () -> (() -> Void)?) -> some View {
        if let action = action() {
            Button(text, action: action)
                .buttonStyle(.plain)
                .underline()
        } else {
            Text(text)
        }
    }
}

/// The words a day heading says: Today, Yesterday, then the date.
enum EventDay {
    static func heading(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// Events newest first, cut into days, newest day first.
    static func grouped(_ events: [Event], calendar: Calendar = .current) -> [(day: Date, events: [Event])] {
        var days: [(day: Date, events: [Event])] = []
        for event in events {
            let day = calendar.startOfDay(for: event.at)
            if days.last?.day == day {
                days[days.count - 1].events.append(event)
            } else {
                days.append((day, [event]))
            }
        }
        return days
    }
}
