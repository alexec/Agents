import AgentsKit
import SwiftUI

/// A question the agent is blocked on, with the agent's own answers.
///
/// Nothing here answers on the user's behalf, remembers an answer, or applies a rule of
/// its own. The way to be asked less often is the runtime's own options, which the
/// start form already offers.
struct PermissionView: View {
    @Environment(AppModel.self) private var model
    let request: PermissionRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(request.toolCall.title).font(.headline)
            } icon: {
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            }
            if let kind = request.toolCall.kind {
                Text(kind).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ForEach(request.options) { option in
                    // The agent's own wording, on the agent's own options.
                    if option.kind.allows {
                        Button(option.name) {
                            Task { await model.answer(request, optionID: option.optionID) }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button(option.name) {
                            Task { await model.answer(request, optionID: option.optionID) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Spacer()
            }
        }
        .padding(14)
        .background(.orange.opacity(0.08))
    }
}
