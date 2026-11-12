import AgentsKitCore
import SwiftUI

/// A suggestion of the read-only daily checks in For Review (#3331), drawn as a pull request's
/// row is (#3330): the mark, the title and its folder, the time, and one grey line, the prompt
/// Start sends. An urgent one has the attention tint. The window and the Remote both draw it;
/// each adds its own Start and Dismiss.
struct CheckSuggestionRowLabel: View {
    let suggestion: CheckSuggestion
    /// Which folder it is in, after the title, as a smart group's rows name theirs.
    var place: String?

    private var urgent: Bool { suggestion.urgent ?? false }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(icon: urgent ? "exclamationmark.circle" : "lightbulb")
                .sidebarMark(AnyShapeStyle(urgent ? StateTint.attention.color ?? Paper.accent : Paper.accent))
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    // White, as every row's title is (#587).
                    Text(suggestion.title)
                        .appText(.supporting)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let place {
                        Text(place)
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                            .layoutPriority(-1)
                    }
                }
                Text(Self.line(suggestion))
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            ActivityTime(date: suggestion.at)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(urgent ? "urgent suggestion of the daily checks" : "suggestion of the daily checks")
    }

    /// The prompt Start sends, on one line.
    static func line(_ suggestion: CheckSuggestion) -> String {
        suggestion.prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
