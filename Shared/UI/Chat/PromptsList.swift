import AgentsKitCore
import SwiftUI

/// The Prompts list (#1658): every prompt the person sent in the chat, oldest first, opened at
/// the newest. A row goes to its prompt in the chat; its menu copies it or branches a new
/// session from just before it. Each is numbered from the chat's first prompt, as the host
/// counts them; while earlier turns are not in hand, a first row says so and loads them (#1862).
///
/// In a sheet, from the chat's ··· menu, and on the Mac the Session menu (⇧⌘P).
struct PromptsList: View {
    let agent: Agent
    /// The chat's page of the transcript: its prompts are the ones in hand.
    let page: AgentsModel
    /// Go to the prompt in the chat. The sheet is closed first.
    let go: @MainActor (SessionPrompt) -> Void
    /// Branch from Here. Nil on an archived session, as Branch is.
    let branch: (@MainActor (SessionPrompt) -> Void)?
    /// Brings the page of turns before the ones in hand.
    let loadEarlier: @MainActor () async -> Void
    let close: () -> Void

    @State private var query = ""
    @State private var isLoadingEarlier = false

    var body: some View {
        // The last turn is going while the chat says it is at work, as the transcript has it.
        let isRunning = [.running, .starting, .waitingOnUser].contains(agent.state)
        let prompts = SessionPrompts.of(turns: page.turns, entries: page.entries, isRunning: isRunning,
                                        earlier: page.firstPrompt ?? 0)
        let shown = SessionPrompts.filtered(prompts, by: query)
        NavigationStack {
            List {
                if page.hasMoreOfTheConversation {
                    earlierRow
                }
                ForEach(shown) { prompt in
                    PromptsListRow(prompt: prompt,
                                   go: { close(); go(prompt) },
                                   branch: branch.map { branch in { close(); branch(prompt) } })
                }
            }
            // Opened at the newest, which is the one most often wanted.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .overlay {
                if prompts.isEmpty {
                    // None in hand while earlier ones are not loaded: the first row says so.
                    if !page.hasMoreOfTheConversation {
                        ContentUnavailableView("No prompts yet", systemImage: "text.bubble")
                    }
                } else if shown.isEmpty {
                    ContentUnavailableView("No prompts match", systemImage: "magnifyingglass")
                }
            }
            .searchable(text: $query, prompt: "Filter prompts")
            .navigationTitle("Prompts")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: close)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 360, idealHeight: 480)
        #endif
        .paperSheet()
    }

    /// The prompts before the page are not in hand: said, with the way to bring them.
    private var earlierRow: some View {
        HStack {
            Text("Earlier prompts aren't loaded")
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if isLoadingEarlier {
                ProgressView().controlSize(.small)
            } else {
                Button("Load Earlier") {
                    isLoadingEarlier = true
                    Task {
                        // Off the end, so the turns brought in are not trimmed away again, as Find does.
                        page.isFollowingEnd = false
                        await loadEarlier()
                        isLoadingEarlier = false
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .appText(.supporting)
    }
}

/// One prompt: its number, its first line, and "‹cost› · ‹length› · ‹time›" under it, with a
/// mark when its turn was stopped or failed.
private struct PromptsListRow: View {
    let prompt: SessionPrompt
    let go: () -> Void
    let branch: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: go) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(prompt.number)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 24, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(prompt.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(prompt.detail())
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    ending
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Goes to this prompt in the chat")
            #if os(iOS)
            // A touch screen has no right click: the row's menu is one tap away too.
            Menu {
                actions
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            #endif
        }
        .appText(.supporting)
        .contextMenu { actions }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Copy", systemImage: "doc.on.doc") { CopiesMessage.copy(prompt.text) }
        if let branch {
            Button("Branch from Here", systemImage: "arrow.triangle.branch", action: branch)
        }
    }

    /// Stopped is the person's own doing and is not tinted; failed is (FR-006).
    @ViewBuilder
    private var ending: some View {
        switch prompt.ending {
        case .stopped?:
            Image(systemName: "stop.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Stopped")
        case .failed?:
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(StateTint.failure.style(or: .secondary))
                .accessibilityLabel("Failed")
        case nil:
            EmptyView()
        }
    }
}
