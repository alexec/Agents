import AgentsKit
import SwiftUI

/// A question the agent is blocked on, with the agent's own answers.
///
/// Nothing here answers on the user's behalf, remembers an answer, or applies a rule of
/// its own. The way to be asked less often is the runtime's own options, which the
/// prompt bar already offers.
struct PermissionView: View {
    @Environment(AppModel.self) private var model
    let request: PermissionRequest

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                Text(request.toolCall.title).font(.headline)
                if let kind = request.toolCall.kind {
                    Text(kind).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    // The agent's own wording, on the agent's own options.
                    ForEach(request.options) { option in
                        if option.kind.allows {
                            Button(option.name) { answer(option) }
                                .buttonStyle(.glassProminent)
                        } else {
                            Button(option.name) { answer(option) }
                                .buttonStyle(.glass)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.horizontal, 20)
    }

    private func answer(_ option: PermissionOption) {
        Task { await model.answer(request, optionID: option.optionID) }
    }
}
