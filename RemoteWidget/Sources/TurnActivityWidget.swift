import ActivityKit
import AgentsKitCore
import SwiftUI
import WidgetKit

/// The turns sent from this phone or iPad, as one activity on the Lock Screen and in the
/// Dynamic Island (#1657, #2991): the session that most needs the person, what it is doing
/// in a word, the line under it, how many others run, and how long they have worked. A tap
/// opens the session, where a question waits as its card (#723).
///
/// Drawn from `TurnActivityContent` and nothing else, as the attention widget is drawn from
/// its snapshot: the Remote decides what it says.
struct TurnActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TurnActivityAttributes.self) { context in
            TurnLockScreen(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Paper.ground)
                .widgetURL(Self.link(context.state))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label { Text(context.state.word) } icon: { TurnMark(phase: context.state.phase) }
                        .appText(.supporting)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TurnTime(state: context.state)
                        .appText(.supporting)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.shownTitle)
                            .appText(.reading)
                            .lineLimit(1)
                        if let line = context.state.line(isStale: context.isStale) {
                            Text(line)
                                .appText(.fine)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if let others = context.state.others {
                            Text(others)
                                .appText(.fine)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                TurnMark(phase: context.state.phase, sessions: context.state.sessions)
            } compactTrailing: {
                TurnTime(state: context.state)
                    .frame(maxWidth: 52)
            } minimal: {
                TurnMark(phase: context.state.phase)
            }
            .widgetURL(Self.link(context.state))
            .keylineTint(Paper.accent)
        }
    }

    /// The session it shows; from a build before #2991, which named none, the attention list.
    static func link(_ state: TurnActivityContent) -> URL {
        state.agentID.map { AttentionLink.agent($0).url } ?? AttentionLink.attention.url
    }
}

/// The Lock Screen's banner: the mark, the title, the word with the runtime and folder,
/// the line, the others, and the time on the right.
struct TurnLockScreen: View {
    let state: TurnActivityContent
    let isStale: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TurnMark(phase: state.phase)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.shownTitle)
                    .appText(.reading)
                    .lineLimit(1)
                Text(([state.word] + [state.place].compactMap(\.self)).joined(separator: " · "))
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let line = state.line(isStale: isStale) {
                    Text(line)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let others = state.others {
                    Text(others)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            TurnTime(state: state)
                .appText(.supporting)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}

/// The sidebar's marks (#495), as symbols, because a Live Activity does not animate a
/// spinner: an orange hand when it needs the person, a tick once done (#2369), a grey stop once paused.
/// In the compact Dynamic Island, with how many sessions when more than one (#2991).
struct TurnMark: View {
    let phase: TurnActivityContent.Phase
    var sessions = 1

    var body: some View {
        if sessions > 1 {
            HStack(spacing: 2) {
                mark
                Text("\(sessions)")
                    .monospacedDigit()
                    .accessibilityLabel("\(sessions) sessions")
            }
        } else {
            mark
        }
    }

    @ViewBuilder private var mark: some View {
        switch phase {
        case .working:
            Image(systemName: "circle.dashed").foregroundStyle(Paper.accent)
                .accessibilityLabel("Working")
        case .question, .approval, .needsYou:
            Image(systemName: "hand.raised.fill").tinted(.attention)
                .accessibilityLabel("Needs you")
        case .done:
            Image(systemName: "checkmark").foregroundStyle(Paper.accent)
                .accessibilityLabel("Done")
        case .paused:
            // A stop the person chose, or a spent allowance: the sidebars' stop mark, not an alarm (#1869).
            Image(systemName: "stop.circle").foregroundStyle(.secondary)
                .accessibilityLabel("Paused")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").tinted(.failure)
                .accessibilityLabel("Unexpected stop")
        }
    }
}

/// How long the turn has worked: counting while it runs, which the system draws without
/// the app, and still once it has ended.
struct TurnTime: View {
    let state: TurnActivityContent

    var body: some View {
        if let ended = state.endedAt {
            Text(Self.duration(from: state.startedAt, to: ended))
                .monospacedDigit()
        } else {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }

    static func duration(from start: Date, to end: Date) -> String {
        let seconds = max(0, end.timeIntervalSince(start))
        let pattern: Duration.TimeFormatStyle.Pattern = seconds >= 3600 ? .hourMinuteSecond : .minuteSecond
        return Duration.seconds(seconds).formatted(.time(pattern: pattern))
    }
}
