import AgentsKitCore
import SwiftUI

/// What you type to the agent, and everything the Mac puts around it (033).
///
/// This used to be much less than the Mac's bar, on purpose: a field, a send button,
/// and the one suggestion. Starting an agent is still its own screen (029). But talking
/// to one is now the same as on the Mac, from top to bottom: where it is working, how
/// full it is and what runs it; the cost limit when it has been reached; what is
/// attached; the runtime's commands and the Mac's files; the field with attach, dictate
/// and send; and the agent's own controls under it.
///
/// Two things differ, both because this is a touch screen. The suggestion is a chip
/// rather than the field's placeholder (031), and a touched file opens the change in a
/// sheet. An iPad with a keyboard gets the Mac's keys.
struct PromptBar: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let agent: Agent
    /// A question or a form is floating above. The bar keeps to its field row while it
    /// is not being typed in, so the question has the room.
    var isQuestionUp = false

    @State private var text = ""
    @State private var attachments: [Attachment] = []
    /// Why something picked could not be attached, said where it was picked.
    @State private var attachRefusal: String?
    @State private var dictation = Dictation()
    @State private var isPrimingDictation = false
    /// Set when the list is put away, so it stays away until the word changes.
    @State private var dismissedCommandTerm: String?
    @State private var selectedCommand = 0
    @State private var mentions: [FileMention] = []
    @State private var mentionSearch: Task<Void, Never>?
    @State private var selectedMention = 0
    @State private var dismissedMentionTerm: String?
    @State private var dismissedSuggestions = false
    /// A draft came back without something it held by value — a picture too large to
    /// keep — and the bar says so until the next thing is sent (025 US5).
    @State private var draftLostSomething = false
    /// How wide the options row has to fill. See `optionsRow`.
    @State private var optionsWidth: CGFloat = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isShowingEverything {
                PromptHeader(agent: agent,
                             projectFolderBranch: model.projectFolderBranches[agent.projectFolder],
                             leaseStatus: model.work.leaseStatus(of: agent.id)) {
                    ContextMeter(agent: agent)
                }
                .task(id: "\(agent.id)-\(agent.state)") { await model.loadProjectFolderBranch(of: agent) }
                CostLimitBanner(agent: agent, limits: model.costLimits, costState: model.costState,
                                goOn: { Task { await model.letThisAgentGoOn(agent) } }) {
                    RaiseTheLimitOnTheMac()
                }
            }
            if !attachments.isEmpty {
                AttachmentStrip(attachments: $attachments,
                                capabilities: model.promptCapabilities(for: agent.runtimeID))
            }
            if let attachRefusal {
                Text(attachRefusal).appText(.fine).tinted(.failure)
            }
            if draftLostSomething {
                Text(PromptWords.draftLostSomething)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
            if isCompleting {
                CommandList(commands: matchingCommands, selected: selectedCommand, choose: accept)
                    .transition(.opacity)
            }
            if isMentioning {
                MentionList(mentions: mentions, selected: selectedMention, choose: accept)
                    .transition(.opacity)
            }
            if let suggestion {
                SuggestionChip(prompt: suggestion, take: take)
                    .transition(.opacity)
            }
            field
            if isShowingEverything { options }
        }
        // The same column the transcript draws in, so the bar's edges track its edges
        // at every width, as on the Mac (FR-020, FR-021).
        .chatColumn()
        .padding(.vertical, 12)
        .animation(.easeOut(duration: 0.15), value: isCompleting)
        .animation(.easeOut(duration: 0.15), value: isMentioning)
        .sheet(isPresented: $isPrimingDictation) { dictationPrimer.paperSheet() }
        .alert("Dictation", isPresented: Binding(get: { dictation.problem != nil },
                                                 set: { if !$0 { dictation.dismissProblem() } })) {
            // Where a switch would fix it, offer to open the switch.
            if let permission = dictation.problem?.permission {
                Button("Open Settings") { UIApplication.shared.open(permission.settings) }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(dictation.problem?.message ?? "")
        }
        .onAppear { restoreDraft() }
        .onChange(of: agent.id) { restoreDraft() }
        .onChange(of: text) {
            selectedCommand = 0
            selectedMention = 0
            if dismissedCommandTerm != commandQuery?.term { dismissedCommandTerm = nil }
            if dismissedMentionTerm != mentionQuery?.term { dismissedMentionTerm = nil }
            updateMentions()
            keepDraft()
        }
        .onChange(of: attachments) { keepDraft() }
        // A new one is a new turn's worth, so it comes back from having been dismissed.
        .onChange(of: agent.suggestedPrompts) { dismissedSuggestions = false }
        // A phone put in a pocket mid-sentence loses nothing.
        .onChange(of: scenePhase) { if scenePhase != .active { StartDraftKeeper.shared.flush() } }
        .onDisappear {
            dictation.stop()
            StartDraftKeeper.shared.flush()
        }
    }

    /// Everything, unless a question is up and the field is not being typed in.
    private var isShowingEverything: Bool { !isQuestionUp || focused }

    // MARK: What you want done

    private var field: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(PromptWords.placeholder(for: agent), text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .appText(.reading)
                .lineLimit(1...8)
                .focused($focused)
                .onChange(of: focused) { _, now in model.isTyping = now }
                .accessibilityLabel("What to say to \(agent.title ?? "this agent")")
                // The Mac's keys, from an iPad's keyboard. SwiftUI hands these over from
                // a hardware keyboard only, so the on-screen one is left as iOS has it:
                // Return is a new line and Send is the button.
                .onKeyPress(.return, phases: .down) { press in
                    guard !press.modifiers.contains(.option) else { return .ignored }
                    if isCompleting || isMentioning { acceptSelected() } else { send() }
                    return .handled
                }
                .onKeyPress(.tab) {
                    if isCompleting || isMentioning {
                        acceptSelected()
                        return .handled
                    }
                    guard let suggestion else { return .ignored }
                    take(suggestion)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    if isCompleting {
                        selectedCommand = min(selectedCommand + 1, matchingCommands.count - 1)
                        return .handled
                    }
                    if isMentioning {
                        selectedMention = min(selectedMention + 1, mentions.count - 1)
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.upArrow) {
                    if isCompleting {
                        selectedCommand = max(selectedCommand - 1, 0)
                        return .handled
                    }
                    if isMentioning {
                        selectedMention = max(selectedMention - 1, 0)
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.escape) {
                    if isCompleting {
                        dismissedCommandTerm = commandQuery?.term
                        return .handled
                    }
                    if isMentioning {
                        dismissedMentionTerm = mentionQuery?.term
                        return .handled
                    }
                    guard suggestion != nil else { return .ignored }
                    dismissedSuggestions = true
                    return .handled
                }

            AttachButton(attachments: $attachments, refusal: $attachRefusal)

            Button(action: toggleDictation) {
                Image(systemName: dictation.isListening ? "waveform" : "microphone")
                    .appText(.reading).fontWeight(.semibold)
                    .frame(width: 22, height: 22)
                    .symbolEffect(.variableColor, isActive: dictation.isListening)
            }
            .buttonStyle(.paper)
            .buttonBorderShape(.circle)
            .accessibilityLabel(dictation.isListening ? "Stop dictating" : "Dictate")

            Button(action: send) {
                Image(systemName: PromptWords.sendSymbol(willQueue: willQueue))
                    .appText(.reading).fontWeight(.semibold)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.paperProminent)
            .buttonBorderShape(.circle)
            .disabled(!canSend)
            .accessibilityLabel(PromptWords.sendLabel(willQueue: willQueue))
            .accessibilityHint(willQueue ? PromptWords.sendHelp(willQueue: true) : "")
        }
        .padding(14)
        .paperRaised(in: RoundedRectangle(cornerRadius: 18))
    }

    private var canSend: Bool {
        !model.isStale && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether what is typed now will wait for the turn to end rather than go.
    private var willQueue: Bool { PromptWords.willQueue(agent) }

    private func send() {
        guard canSend else { return }
        dictation.stop()
        let outgoing = text
        let going = attachments
        text = ""
        attachments = []
        attachRefusal = nil
        draftLostSomething = false
        // Whatever was suggested has been answered, by being taken or by being typed
        // past. An emptied field must not offer last turn's words back.
        dismissedSuggestions = true
        // What you just sent is the thing you want to see, so the conversation comes
        // back to its end even if you were reading three screens up.
        model.scrollToEnd()
        let agentID = agent.id
        Task {
            let went = await model.send(outgoing, attachments: going, to: agentID)
            if went {
                StartDraftKeeper.shared.clear(.agent(agentID))
            } else if text.isEmpty, attachments.isEmpty {
                // The field emptied at once so sending felt immediate, but a prompt that
                // did not go is given back rather than lost, unless something new has
                // been typed in the meantime.
                text = outgoing
                attachments = going
            }
        }
    }

    // MARK: Said instead of typed

    private func toggleDictation() {
        if dictation.isListening {
            dictation.stop()
        } else if dictation.hasBeenAsked {
            beginDictation()
        } else {
            isPrimingDictation = true
        }
    }

    private func beginDictation() {
        focused = true
        // What is already in the field is the start of the sentence, not something to
        // be spoken over.
        dictation.start(appendingTo: text.trimmingCharacters(in: .whitespacesAndNewlines)) { combined in
            text = combined
        }
    }

    /// Our own words before the system's alert, the first time only.
    private var dictationPrimer: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(PromptWords.dictationPrimerTitle).appText(.reading).fontWeight(.semibold)
            Text("The phone listens while the button is on, and what you say becomes the words in the prompt. It is recognised on this phone where this phone can do it.")
                .foregroundStyle(.secondary)
            Text("iOS will ask for the microphone and for speech recognition next.")
                .appText(.supporting)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Not now") { isPrimingDictation = false }
                    .buttonStyle(.paper)
                Button("Continue") {
                    isPrimingDictation = false
                    beginDictation()
                }
                .buttonStyle(.paperProminent)
            }
        }
        .padding(20)
        .presentationDetents([.medium])
    }

    // MARK: Kept against this conversation

    private var draftKey: DraftKey { .agent(agent.id) }

    /// This conversation's own, files and all. Words typed for one agent never reach
    /// the next: the bar only ever holds what belongs to where it is.
    private func restoreDraft() {
        let draft = StartDraftKeeper.shared.draft(for: draftKey)
        text = draft?.text ?? ""
        attachments = draft?.attachments ?? []
        draftLostSomething = draft?.droppedInlineData ?? false
        dismissedSuggestions = false
    }

    private func keepDraft() {
        if text.isEmpty, attachments.isEmpty {
            StartDraftKeeper.shared.clear(draftKey)
        } else {
            StartDraftKeeper.shared.note(text, attachments, for: draftKey)
        }
    }

    // MARK: The runtime's commands

    /// This runtime's, and this agent's — the Claude adapter advertises the skills that
    /// happen to be installed, and Copilot thirty-odd of its own. Never a list of ours.
    private var commandQuery: SlashQuery? { SlashCommand.query(in: text) }

    private var matchingCommands: [SlashCommand] {
        guard let commandQuery else { return [] }
        return SlashCommand.matching(commandQuery.term, in: agent.availableCommands)
    }

    private var isCompleting: Bool {
        guard let commandQuery, !matchingCommands.isEmpty else { return false }
        return dismissedCommandTerm != commandQuery.term
    }

    private func accept(_ command: SlashCommand) {
        guard let commandQuery else { return }
        text = command.completing(commandQuery, in: text)
        selectedCommand = 0
        focused = true
    }

    private func acceptSelected() {
        if isMentioning, mentions.indices.contains(selectedMention) {
            accept(mentions[selectedMention])
            return
        }
        guard matchingCommands.indices.contains(selectedCommand) else { return }
        accept(matchingCommands[selectedCommand])
    }

    // MARK: Files named with an @, found on the Mac

    private var mentionQuery: MentionQuery? { FileMention.query(in: text) }

    private var isMentioning: Bool {
        guard let mentionQuery, !mentions.isEmpty else { return false }
        return dismissedMentionTerm != mentionQuery.term
    }

    /// The Mac walks its own disk for these; a phone asks the Mac to. What was typed
    /// since is the search that matters, so each keystroke cancels the last.
    private func updateMentions() {
        mentionSearch?.cancel()
        guard let mentionQuery, !mentionQuery.term.isEmpty else {
            mentions = []
            return
        }
        let term = mentionQuery.term
        let agentID = agent.id
        mentionSearch = Task {
            // A beat, so a word typed quickly is one question to the Mac, not six.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let found = await model.mentions(term, for: agentID)
            guard !Task.isCancelled else { return }
            mentions = found
        }
    }

    /// The name goes in the words, and the file goes with them as the Mac's own path:
    /// the agent reads it on the Mac, so nothing is copied across the link.
    private func accept(_ mention: FileMention) {
        guard let mentionQuery else { return }
        text = mention.completing(mentionQuery, in: text)
        attachments.append(.file(mention.url))
        mentions = []
        selectedMention = 0
        focused = true
    }

    // MARK: What the agent thinks you might ask (031)

    /// Only while the field is empty: half a typed thought is already an answer to what
    /// was suggested. Only while no list is up.
    private var suggestion: SuggestedPrompt? {
        guard !dismissedSuggestions, text.isEmpty, !isCompleting, !isMentioning, !model.isStale else {
            return nil
        }
        return agent.suggestedPrompts.first
    }

    /// The words land in the field rather than going. The agent wrote them; sending
    /// them is still the person's move.
    private func take(_ suggestion: SuggestedPrompt) {
        text = suggestion.prompt
        focused = true
    }

    // MARK: Whatever this runtime offers

    @ViewBuilder
    private var options: some View {
        let state = model.controlsState(for: agent)
        if case .controls(let shown) = state {
            optionsRow(shown)
        } else {
            OptionsNote(state: state)
        }
    }

    /// What the agent is allowed to do first, how well it does it after: permissions on
    /// the left, and the model, its thinking and its speed on the right — the Mac's
    /// order. It scrolls sideways, as the Mac's does in a narrow window, rather than
    /// wrapping or cutting a control short; the row is given a floor of its own width
    /// so the spacer has something to push against.
    private func optionsRow(_ shown: [ConfigOption]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(shown.filter(\.isAboutPermission)) { option in
                    OptionMenu(option: option, chosen: binding(for: option))
                }
                Spacer(minLength: 16)
                ForEach(shown.filter { !$0.isAboutPermission }) { option in
                    OptionMenu(option: option, chosen: binding(for: option))
                }
            }
            .padding(.vertical, 1)
            .frame(minWidth: optionsWidth, alignment: .leading)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { optionsWidth = $0 }
        .disabled(model.isStale)
    }

    private func binding(for option: ConfigOption) -> Binding<JSONValue?> {
        Binding(
            get: { model.chosenOption(option.id, for: agent, advertised: option) },
            set: { value in
                guard let value else { return }
                model.setOption(agentID: agent.id, optionID: option.id, value: value)
            })
    }
}

/// The one thing the agent thinks you might ask next (031).
///
/// One chip, cut short at the width rather than scrolled: there is nothing beside it
/// to scroll to, and a scroller holding one thing reads as broken.
private struct SuggestionChip: View {
    let prompt: SuggestedPrompt
    let take: (SuggestedPrompt) -> Void

    var body: some View {
        Button { take(prompt) } label: {
            Text(prompt.label)
                .appText(.fine)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .paperRaised(in: .capsule)
        .padding(.horizontal, 2)
        .frame(height: 36)
        .accessibilityHint("Puts this in the prompt. Nothing is sent yet.")
    }
}
