import AgentsKitCore
import SwiftUI

/// What you type to the agent, and everything the Mac puts around it (033).
///
/// This used to be much less than the Mac's bar, on purpose: a field, a send button,
/// and the one suggestion. Starting an agent is still its own screen (029). But talking
/// to one is now the same as on the Mac, from top to bottom: where it is working, how
/// full it is and what runs it; the cost limit when it has been reached; what is
/// attached; the runtime's commands and the Mac's files; then one outlined composer with
/// its field above its attach, dictate, voice and send actions; and the agent's controls under it.
///
/// Two things differ, both because this is a touch screen. The suggestion is a chip
/// rather than the field's placeholder (031), and a touched file opens the change in a
/// sheet. An iPad with a keyboard gets the Mac's keys.
struct PromptBar: View {
    @Environment(RemoteModel.self) private var model
    /// Set in a scene of its own (#888): its session, not the selection.
    @Environment(\.poppedChat) private var popped
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.chatActions) private var chatActions
    let agent: Agent
    /// A question or a form is floating above. The bar keeps to its field row while it
    /// is not being typed in, so the question has the room.
    var isQuestionUp = false

    @State private var text = ""
    /// How far back Up has gone through the prompts sent here; nil at the prompt bar's
    /// own text (#1551).
    @State private var recalled: Int?
    /// The prompts the person sent in this chat, oldest first: what Up gives back.
    private var sentPrompts: [String] { model.page(popped).sentPrompts }
    /// Where the cursor is in `text`, so dictation can write there rather than at the
    /// end (#427).
    @State private var selection: TextSelection?
    @State private var attachments: [Attachment] = []
    /// Why something picked could not be attached, said where it was picked.
    @State private var attachRefusal: String?
    @State private var dictation = Dictation()
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
    /// Prompts this bar has sent that the Mac has not yet taken (#87). The send button
    /// spins meanwhile; past a beat, the bar says so in words too, as the Mac's does.
    @State private var sending = 0
    @State private var sendingIsSlow = false
    /// How wide the options row has to fill. See `optionsRow`.
    @State private var optionsWidth: CGFloat = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isShowingEverything {
                // Where it works, its labels and its runtime, over the field as on the
                // window and the page (#108, #242).
                PromptHead(agent: agent)
                PromptHeader(agent: agent,
                             background: agent.background,
                             backgroundActions: BackgroundActions(
                                stop: { [model] item in await model.stopBackground(item, of: agent.id) },
                                steps: { [chatActions] item in chatActions.subagentSteps?(item.id) }),
                             // One line on a phone, the Mac's rows on an iPad (frame E).
                             compactBackground: sizeClass == .compact)
                CostLimitBanner(agent: agent, limits: model.costLimits, costState: model.costState,
                                goOn: { Task { await model.letThisAgentGoOn(agent) } }) {
                    RaiseTheLimitOnTheMac()
                }
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
            if sending > 0, sendingIsSlow {
                Telling(host: model.answerRecipient(agent.id), doing: "Sending")
            }
            // Voice mode (#2322) is the whole bar, field and options: what it hears and
            // says, and Stop to end it (#2375, #2517).
            if VoiceMode.shared.isOn(in: agent.id) {
                VoiceModeBar()
            } else {
                field
                if isShowingEverything { options }
            }
        }
        .task(id: sending > 0) {
            sendingIsSlow = false
            guard sending > 0 else { return }
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { sendingIsSlow = true }
        }
        // The same column the transcript draws in, so the bar's edges track its edges
        // at every width, as on the Mac (FR-020, FR-021).
        .chatColumn()
        .padding(.vertical, 12)
        .animation(.easeOut(duration: 0.15), value: isCompleting)
        .animation(.easeOut(duration: 0.15), value: isMentioning)
        .onAppear { restoreDraft() }
        .onChange(of: agent.id) { restoreDraft() }
        // Voice mode listens with its own dictation: this bar's stops, so the same words do
        // not go two ways (#2445).
        .onChange(of: VoiceMode.shared.isOn) { _, isOn in
            if isOn { dictation.stop() }
        }
        // Opened: its runtime starts now, so the reply does not wait for it (#183). Once
        // it has been on screen a moment, so paging past chats starts nothing (#202).
        .task(id: agent.id) {
            try? await Task.sleep(for: DaemonAPI.PrewarmRequest.openedAfter)
            guard !Task.isCancelled else { return }
            await model.prewarm(agent.id, .opened)
        }
        .onChange(of: text) {
            selectedCommand = 0
            selectedMention = 0
            if dismissedCommandTerm != commandQuery?.term { dismissedCommandTerm = nil }
            if dismissedMentionTerm != mentionQuery?.term { dismissedMentionTerm = nil }
            updateMentions()
            keepDraft()
            // Typed while dictating: theirs, and never written over (#427).
            dictation.edited(text)
            // Typing is a prompt coming (#183).
            if !text.isEmpty { Task { await model.prewarm(agent.id, .typing) } }
        }
        .onChange(of: selection) {
            if let range = DictationCursor.range(of: selection, in: text) { dictation.selected(range) }
        }
        .onChange(of: attachments) { keepDraft() }
        // A new one is a new turn's worth, so it comes back from having been dismissed.
        .onChange(of: agent.suggestedPrompts) { dismissedSuggestions = false }
        // Words offered from elsewhere in the chat (#1552): they land in the field, focused
        // and unsent, as on the Mac; after what is typed, never over it (#1665).
        // Only this chat's (#1679): another scene's are left for its own bar.
        .onChange(of: model.offeredPrompt) {
            guard let offered = model.offeredPrompt, offered.agentID == agent.id else { return }
            text = PromptQuote.givingBack(offered.words, to: text)
            focused = true
            model.offeredPrompt = nil
        }
        // Quote in Prompt (#1553): added after what is typed, the caret after it.
        .onChange(of: model.offeredQuote) {
            guard let quote = model.offeredQuote, quote.agentID == agent.id else { return }
            text = PromptQuote.adding(quote.words, to: text)
            focused = true
            model.offeredQuote = nil
        }
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
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                AttachmentStrip(attachments: $attachments,
                                capabilities: model.promptCapabilities(for: agent.runtimeID))
            }
            TextField(policyRefusal ?? PromptWords.placeholder(for: agent), text: $text, selection: $selection, axis: .vertical)
                .textFieldStyle(.plain)
                .appText(.reading)
                .lineLimit(2...8)
                .overlay(alignment: .topLeading) { HeardUnderline(dictation: dictation, text: text) }
                .focused($focused)
                .onChange(of: focused) { _, now in model.isTyping = now }
                // ⌘V of a picture from an iPad's keyboard attaches it (#396).
                .modifier(PastesPictures(attachments: $attachments, refusal: $attachRefusal))
                .accessibilityLabel("What to say to \(agent.title ?? "this agent")")
                // The Mac's keys, from an iPad's keyboard. SwiftUI hands these over from
                // a hardware keyboard only, so the on-screen one is left as iOS has it:
                // Return is a new line and Send is the button. From a hardware keyboard,
                // Return sends, and Shift-Return and Option-Return are a new line (#377, #1514).
                .onKeyPress(.return, phases: .down) { press in
                    guard PromptReturn(option: press.modifiers.contains(.option),
                                       shift: press.modifiers.contains(.shift)) == .send else { return .ignored }
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
                    // The prompts sent before, as a terminal gives back its commands (#1551).
                    if let step = PromptHistory.recall(.down, text: text, sent: sentPrompts, at: recalled) {
                        text = step.text
                        recalled = step.at
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
                    // The prompts sent before, as a terminal gives back its commands (#1551).
                    if let step = PromptHistory.recall(.up, text: text, sent: sentPrompts, at: recalled) {
                        text = step.text
                        recalled = step.at
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
                .frame(minHeight: 44, alignment: .topLeading)

            HStack(spacing: 8) {
                AttachButton(attachments: $attachments, refusal: $attachRefusal)

                Spacer(minLength: 0)
                // Dictate and voice mode sit with send, on the right (#2634).
                DictateButton(dictation: dictation, begin: beginDictation, send: send)

                // Voice mode (#2322), while Settings ▸ Voice has it on.
                VoiceModeButton(agentID: agent.id, vocabulary: { speechSeeds }) { words, stopping in
                    if let stopping { await model.stop(stopping) }
                    return await model.send(words, to: agent.id, voice: true) ? agent.id : nil
                }

                // While it works and nothing is typed, send is stop. Type and it is send
                // again, queueing what is typed for when the turn ends.
                if model.canStop(agent), !model.isStale(agent), text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   sending == 0 {
                    let acting = model.acting(agent.id)
                    Button {
                        Task { await model.stop(agent.id) }
                    } label: {
                        Group {
                            if acting == .stop {
                                ProgressView()
                            } else {
                                Image(systemName: PromptWords.stopSymbol)
                                    .appText(.reading).fontWeight(.semibold)
                            }
                        }
                        .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.paperProminent)
                    .buttonBorderShape(.circle)
                    // Held while something else is on its way to this agent. Not while it is Stop: (#87).
                    // the one that went stays bright, as on the answer cards (#86), and the
                    // model refuses a second press.
                    .disabled(acting != nil && acting != .stop)
                    .help(PromptWords.stopHelp)
                    .accessibilityLabel("Stop")
                    .accessibilityValue(acting == .stop ? Telling.words(doing: "Stopping", host: "your Mac") : "")
                } else {
                    Button(action: send) {
                        Group {
                            if sending > 0 {
                                ProgressView()
                            } else {
                                Image(systemName: PromptWords.sendSymbol(willQueue: willQueue))
                                    .appText(.reading).fontWeight(.semibold)
                            }
                        }
                        .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.paperProminent)
                    .buttonBorderShape(.circle)
                    // Bright while its own spinner turns, as the answer that went stays bright
                    // on the cards (#86); `send()` refuses the press meanwhile.
                    .disabled(!canSend && sending == 0)
                    .accessibilityLabel(PromptWords.sendLabel(willQueue: willQueue))
                    .accessibilityHint(willQueue ? PromptWords.sendHelp(willQueue: true) : "")
                }
            }
        }
        .padding(10)
        .frame(minHeight: 94, alignment: .topLeading)
        .paperRaised(in: RoundedRectangle(cornerRadius: 18))
    }

    /// Why nothing can be sent on the Mac's host now, in its organisation's words (#998). A
    /// server says its own when it refuses.
    private var policyRefusal: String? {
        agent.host == .mac ? model.policyState?.composerReason : nil
    }

    private var canSend: Bool {
        guard policyRefusal == nil else { return false }
        // A stopped workspace that starts when used keeps what is sent until it is up (#691 US3).
        return (!model.isStale(agent) || model.startsWhenUsed(agent.host)) && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        // The keyboard goes (#2091): the reply is what comes next, and an open keyboard
        // hides half of it. A tap on the field brings it back.
        focused = false
        // What you just sent is the thing you want to see, so the conversation comes
        // back to its end even if you were reading three screens up.
        if let popped { popped.scrollToEnd() } else { model.scrollToEnd() }
        let agentID = agent.id
        Task {
            sending += 1
            let went = await model.send(outgoing, attachments: going, to: agentID)
            sending -= 1
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

    /// The open folders, and this folder's titles and issue numbers (#2515). Read only when
    /// dictation or voice mode starts, never in `body` (#2732).
    private var speechSeeds: [String] {
        DictationVocabulary.seeds(folders: model.work.folders, agents: model.work.agents, in: agent.folderPath)
    }

    private func beginDictation() {
        focused = true
        // What is already in the field stays, and the words go in at the cursor.
        dictation.start(in: text, selection: DictationCursor.range(of: selection, in: text),
                        vocabulary: speechSeeds) { field, cursor in
            text = field
            selection = DictationCursor.selection(cursor, in: field)
        }
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
        guard !dismissedSuggestions, text.isEmpty, !isCompleting, !isMentioning, !model.isStale(agent) else {
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
            VStack(alignment: .leading, spacing: 8) {
                OptionsNote(state: state)
                if ClientPermissionSettings.supports(agent.runtimeID) {
                    optionsRow([])
                }
            }
        }
    }

    /// What the agent is allowed to do first, how well it does it after: permissions on
    /// the left, and the model, its thinking and its speed on the right — the Mac's
    /// order. It scrolls sideways, as the Mac's does in a narrow window, rather than
    /// wrapping or cutting a control short; the row is given a floor of its own width
    /// so the spacer has something to push against.
    /// A Model or Permission mode pill (#2658), as the Mac's.
    private func levelPill(_ field: AutoField, own: [ConfigOption]) -> some View {
        LevelPill(field: field,
                  chosen: field == .model ? agent.levels?.model?.rawValue : agent.levels?.permission?.rawValue,
                  runtimeName: PromptWords.runtimeName(agent.runtimeID),
                  cell: { model.autoMappings.cell(agent.runtimeID, field, $0) },
                  own: own, binding: binding(for:)) { level in
            Task { await model.setAgentLevel(agent.id, field, level) }
        }
    }

    private func optionsRow(_ shown: [ConfigOption]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                if ClientPermissionSettings.supports(agent.runtimeID) {
                    ClientPermissionCapsule(runtimeID: agent.runtimeID, own: agent.clientPermission,
                                            settings: model.clientPermissions.mode(for: agent.runtimeID)) { mode in
                        Task { await model.setAgentClientPermission(agent.id, mode) }
                    }
                }
                // The permission mode in the shared words (#2658), the runtime's own behind ⋯.
                let permissions = shown.filter(\.isAboutPermission)
                if !permissions.isEmpty || model.autoMappings.cell(agent.runtimeID, .permission, "ask")?.native != nil {
                    levelPill(.permission, own: permissions)
                }
                // The command sandbox, beside the mode, as on the Mac (064).
                SandboxCapsule(runtimeID: agent.runtimeID,
                               override: agent.sandboxOverride,
                               runtimeDefault: model.sandboxSettings.choice(for: agent.runtimeID),
                               codexMode: agent.startOptions.values["mode"]?.stringValue,
                               effective: agent.effectiveSandbox,
                               isWorking: agent.state == .running,
                               setBy: model.sandboxSettings.setBy) { choice in
                    Task { await model.setAgentSandbox(agent.id, choice) }
                }
                Spacer(minLength: 16)
                let others = shown.filter { !$0.isAboutPermission }
                if !others.isEmpty {
                    levelPill(.model, own: others)
                }
                // What it has used, beside how it thinks.
                ContextMeter(agent: agent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .paperRaised(in: Capsule())
            }
            .padding(.vertical, 1)
            .frame(minWidth: optionsWidth, alignment: .leading)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { optionsWidth = $0 }
        .disabled(model.isStale(agent))
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

/// Over the field, as the window and the page have it (#108, #242): where the agent
/// works, its labels, and the runtime it is on. The place is said, not offered: moving a
/// session to another worktree (053) is the window's.
private struct PromptHead: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent
    /// The folder's branch, for an agent working there rather than in a worktree.
    @State private var folderBranch: String?
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// At compact width the labels are one line, and a tap opens them in a popover (#2173).
    @State private var editingLabels = false

    var body: some View {
        HStack(alignment: sizeClass == .compact ? .center : .top, spacing: 10) {
            if let place {
                Text(place)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .appText(.fine)
                    .paperRaised(in: .capsule)
                    .accessibilityLabel("Worktree: \(place)")
            }
            // The labels take the width the place leaves, not half of it: a Spacer beside
            // them was as flexible as their wrapping row, so the two split it and the
            // chips wrapped beside empty space (#670).
            labels
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(PromptWords.runtimeName(agent, accounts: model.accountProfiles))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .appText(.fine)
                .fixedSize()
                .paperRaised(in: .capsule)
                .accessibilityLabel("Runtime: \(PromptWords.runtimeName(agent, accounts: model.accountProfiles))")
        }
        // Asked once a chat, as the window asks: the branch is not on the agent's record.
        .task(id: "\(agent.id)-\(agent.cwd.path)") {
            folderBranch = agent.worktree == nil ? await model.folderPathBranch(of: agent) : nil
        }
    }

    /// On an iPhone, one line: the first label and +N, or Add label with none. A tap opens
    /// the whole field in a popover, focused, so the head stays one line and the chat does
    /// not move (#2173). The iPad has the room for the field (#1107).
    @ViewBuilder private var labels: some View {
        if sizeClass != .compact {
            RemoteSessionLabels(agent: agent, compact: false)
        } else {
            Button { editingLabels = true } label: {
                if agent.labels.isEmpty {
                    Label("Add label", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                } else {
                    RemoteCompactLabelRow(labels: agent.labels)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(agent.labels.isEmpty
                ? "Add label"
                : "Labels: \(agent.labels.map(\.value).joined(separator: ", "))")
            .accessibilityHint("Edits the labels.")
            .popover(isPresented: $editingLabels, arrowEdge: .bottom) {
                labelEditor
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    /// The whole field, as the iPad has it. Each change applies as it is made, so a tap
    /// outside closes it as Done does.
    private var labelEditor: some View {
        VStack(alignment: .trailing, spacing: 8) {
            LabelTagField(labels: agent.labels,
                          suggestions: model.labelSuggestions(in: agent.folderPath),
                          add: { values in Task { _ = await model.setLabels(on: agent.id, add: values) } },
                          remove: { value in Task { _ = await model.setLabels(on: agent.id, remove: [value]) } },
                          focusFirst: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Done") { editingLabels = false }
                .appText(.fine)
                .buttonStyle(.plain)
                .foregroundStyle(Paper.accent)
        }
        .padding(12)
        .frame(width: 300)
    }

    /// Its worktree, or the folder's branch. None for an archived agent, whose
    /// place may be gone, as on the window.
    private var place: String? {
        guard agent.state != .archived else { return nil }
        return agent.worktree?.name ?? folderBranch
    }
}
