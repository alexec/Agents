import AgentsKit
import SwiftUI

/// A question the agent is blocked on, with the agent's own answers.
///
/// Nothing here answers on the user's behalf, remembers an answer, or applies a rule of
/// its own. The way to be asked less often is the runtime's own options, which the
/// prompt bar already offers.
///
/// The answers stack rather than sitting in a row. Approving a plan offers five, each a
/// sentence ("Yes, clear context and use auto mode"), and a row of those is five
/// truncated words: an answer the person cannot read is one they cannot give.
struct PermissionView: View {
    @Environment(AppModel.self) private var model
    @Environment(SidebarFrame.self) private var frame
    @Environment(SidebarStates.self) private var states
    let request: PermissionRequest

    var body: some View {
        GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                Text(request.toolCall.title).appText(.reading).fontWeight(.semibold)
                if let kind = request.toolCall.kind, !request.toolCall.isPlanApproval {
                    Text(kind).appText(.fine).foregroundStyle(.secondary)
                }
                plan
                VStack(alignment: .leading, spacing: 6) {
                    // The agent's own wording, on the agent's own options.
                    ForEach(request.options) { option in
                        if option.kind.allows {
                            Button { answer(option) } label: { label(option) }
                                .buttonStyle(.paperProminent)
                        } else {
                            Button { answer(option) } label: { label(option) }
                                .buttonStyle(.paper)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paperRaised(in: RoundedRectangle(cornerRadius: 16))
        }
        // Floats above the prompt bar, in its column.
        .chatColumn()
    }

    /// The plan being approved. As a page in the files pane when the runtime wrote it
    /// to a file — opened there by the daemon when it was asked — and here, in the
    /// card, when it only sent the text.
    @ViewBuilder
    private var plan: some View {
        if let file = request.toolCall.planFile {
            HStack(spacing: 8) {
                Text("The plan is open beside this conversation.")
                    .appText(.fine).foregroundStyle(.secondary)
                Button("Show plan") { show(file) }
                    .buttonStyle(.paper)
            }
        } else if let text = request.toolCall.planText {
            ScrollView {
                Text((try? AttributedString(markdown: text, options: .init(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                    .appText(.reading)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
        }
    }

    /// Full width and wrapping rather than truncating.
    private func label(_ option: PermissionOption) -> some View {
        Text(option.name)
            .multilineTextAlignment(.leading)
            // Wraps in the width it is given. Not `fixedSize`: measured at no width, a
            // fixed-height sentence is one letter a line, and the card pushed the whole
            // window's layout a thousand points past its bottom edge.
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The same as the daemon's own showing of it: the files pane, open on the plan.
    private func show(_ file: ShownFile) {
        let state = states.state(for: request.agentID)
        state.folder = file.url.deletingLastPathComponent()
        state.openFile = file.url
        state.openLine = nil
        frame.pane = .files
        if !frame.isOpen { frame.open() }
    }

    private func answer(_ option: PermissionOption) {
        Task { await model.answer(request, optionID: option.optionID) }
    }
}
