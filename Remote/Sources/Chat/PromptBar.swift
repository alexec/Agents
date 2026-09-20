import AgentsKitCore
import SwiftUI

/// What you type to the agent, and the two things offered around it.
///
/// Much less than the Mac's bar, and the difference is the point. The Mac's is one
/// view that both starts an agent and talks to one, carrying the runtime, mode, model,
/// effort and permission controls; this one talks to an agent that already exists.
/// Starting one from the iPad is its own screen (T072) because the controls that go
/// with it do not belong over a conversation on a phone.
///
/// Two things are offered here, both the runtime's or the agent's rather than ours:
/// the commands this runtime takes, while a slash word is being typed (T067), and the
/// prompts the agent suggested, while the field is empty (T069).
struct PromptBar: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent

    @State private var text = ""
    /// Set when the list is put away, so it stays away until the word changes.
    @State private var dismissedCommandTerm: String?
    @State private var dismissedSuggestions = false
    @State private var isSending = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isCompleting {
                CommandList(commands: matchingCommands, choose: accept)
                    .transition(.opacity)
            }
            if !suggestions.isEmpty {
                SuggestionRow(prompts: suggestions, take: take)
                    .transition(.opacity)
            }
            field
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
        .animation(.easeOut(duration: 0.15), value: isCompleting)
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focused)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
                .accessibilityLabel("What to ask \(agent.title ?? "this agent")")

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.4)
            .accessibilityLabel("Send")
        }
    }

    /// Says what will happen to it, which is not always "sent now". An agent that is
    /// working takes a prompt and gets to it after this turn; saying so here is the
    /// difference between a queue and a message that seems to have gone nowhere.
    private var placeholder: String {
        if model.isStale { return "Your Mac is not answering" }
        return agent.state.holdsRuntime ? "Ask next…" : "Ask…"
    }

    private var canSend: Bool {
        !model.isStale && !isSending
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let what = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !what.isEmpty else { return }
        isSending = true
        Task {
            // Cleared only once it has gone. A prompt that could not be delivered is
            // left in the field to be sent again rather than lost to a failed call.
            if await model.send(what, to: agent.id) {
                text = ""
                dismissedSuggestions = false
            }
            isSending = false
        }
    }

    // MARK: The runtime's commands (T067)

    /// This runtime's, and this agent's — the Claude adapter advertises the skills that
    /// happen to be installed, and Copilot thirty-odd of its own. Never a list of ours.
    private var query: SlashQuery? { SlashCommand.query(in: text) }

    private var matchingCommands: [SlashCommand] {
        guard let query else { return [] }
        return SlashCommand.matching(query.term, in: agent.availableCommands)
    }

    private var isCompleting: Bool {
        guard let query, !matchingCommands.isEmpty else { return false }
        return dismissedCommandTerm != query.term
    }

    private func accept(_ command: SlashCommand) {
        guard let query else { return }
        text = command.completing(query, in: text)
        focused = true
    }

    // MARK: What the agent thinks you might ask (T069)

    /// Only while the field is empty: half a typed thought is already an answer to
    /// what was suggested, and a chip sitting behind it would be noise.
    private var suggestions: [SuggestedPrompt] {
        guard !dismissedSuggestions, text.isEmpty, !model.isStale else { return [] }
        return Array(agent.suggestedPrompts.prefix(SuggestedPrompt.limit))
    }

    /// The words land in the field rather than going. The agent wrote them; sending
    /// them is still the person's move.
    private func take(_ suggestion: SuggestedPrompt) {
        text = suggestion.prompt
        focused = true
    }
}

/// What the runtime takes after a slash, offered while it is being typed.
private struct CommandList: View {
    let commands: [SlashCommand]
    let choose: (SlashCommand) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(commands) { command in
                    Button { choose(command) } label: { row(command) }
                        .buttonStyle(.plain)
                }
            }
            .padding(6)
        }
        .frame(maxHeight: 200)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
    }

    /// The name, then what it wants after it, then what it is for. No selection and no
    /// arrow keys: on a touch screen the row is the way to choose it.
    private func row(_ command: SlashCommand) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("/" + command.name)
                    .font(.footnote.monospaced())
                if let hint = command.inputHint, !hint.isEmpty {
                    Text(hint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            if let description = command.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}

/// The few things the agent thinks you might ask next.
///
/// Chips in a row that scrolls, because a suggestion can be a sentence and four of
/// them wrapped would be a screen of the conversation given to what nobody asked for.
private struct SuggestionRow: View {
    let prompts: [SuggestedPrompt]
    let take: (SuggestedPrompt) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(prompts) { prompt in
                    Button { take(prompt) } label: {
                        Text(prompt.label)
                            .font(.footnote)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .accessibilityHint("Puts this in the prompt. Nothing is sent yet.")
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
        .frame(height: 36)
    }
}
