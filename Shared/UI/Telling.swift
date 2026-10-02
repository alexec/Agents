import SwiftUI

/// What something sent looks like while it is on its way: a small spinner and "telling
/// your Mac", on the control that sent it, with every control that would send it again
/// held, so a double click or a repeated key is not a second action. First on the
/// permission and question cards (#86), then on start, send, Send now, stop, park and
/// archive (#87), in both apps.
///
/// Inside a button's own label rather than over it: a card or a row is often the button,
/// and anything laid over it keeps the clicks.
struct Telling: View {
    let host: String
    /// What is being done, said first ("Archiving — telling your Mac"); nil where the
    /// button beside it already says ("Allow once  telling your Mac").
    var doing: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(Self.words(doing: doing, host: host))
                .appText(.fine)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    static func words(doing: String?, host: String) -> String {
        guard let doing else { return "telling \(host)" }
        return "\(doing) — telling \(host)"
    }
}
