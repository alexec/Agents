import AgentsKit
import SwiftUI

/// One dot per installed runtime, in the rule table's order (C Claude · X Codex · G Grok ·
/// U Cursor · P Copilot · M Gemini · A Antigravity): filled when it gets the thing, struck through and
/// faint when it does not, dashed when nobody has checked.
///
/// Hidden from accessibility: every row it sits in says the same in its one label, and a
/// label under a label crashes AppKit's first accessibility query (memory).
struct ReachDots: View {
    let runtimes: [DaemonAPI.RuntimeName]
    let reach: [String: DaemonAPI.Reach]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(runtimes) { runtime in
                Dot(letter: Self.letter(runtime.id), state: reach[runtime.id])
            }
        }
        .accessibilityHidden(true)
    }

    static func letter(_ runtimeID: String) -> String {
        ["claude": "C", "codex": "X", "grok": "G", "cursor": "U", "copilot": "P", "gemini": "M", "antigravity": "A"][runtimeID]
            ?? String(runtimeID.prefix(1)).uppercased()
    }

    /// What a row's accessibility label says about its dots.
    static func spoken(_ runtimes: [DaemonAPI.RuntimeName], _ reach: [String: DaemonAPI.Reach]) -> String {
        let reached = runtimes.filter { reach[$0.id]?.gets == true }.map(\.name)
        let rest = runtimes.filter { reach[$0.id].map { !$0.gets } ?? false }.map(\.name)
        var words = reached.isEmpty ? "no agent gets it" : "\(reached.joined(separator: ", ")) \(reached.count == 1 ? "gets" : "get") it"
        if !rest.isEmpty { words += "; not \(rest.joined(separator: ", "))" }
        return words
    }

    private struct Dot: View {
        let letter: String
        let state: DaemonAPI.Reach?

        var body: some View {
            Text(letter)
                // Decorative: a runtime's letter in its dot, sized to the dot; the row says it in words.
                .font(.system(size: 10, weight: .semibold, design: .serif))
                .strikethrough(isNo)
                .foregroundStyle(isGets ? SharedInk.reach : .secondary)
                .frame(width: 18, height: 18)
                .background(isGets ? SharedInk.reach.opacity(0.14) : (isNo ? Paper.wash : .clear), in: Circle())
                .overlay {
                    if isUnchecked {
                        Circle().strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                }
                .opacity(isNo ? 0.55 : 1)
        }

        private var isGets: Bool { state?.gets == true }
        private var isUnchecked: Bool { if case .unchecked = state { true } else { false } }
        private var isNo: Bool { state != nil && !isGets && !isUnchecked }
    }
}
