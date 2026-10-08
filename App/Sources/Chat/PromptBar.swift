import AgentsKitCore
import SwiftUI
import UniformTypeIdentifiers

/// The prompt, and the controls around it.
///
/// The same thing before an agent exists and after. Starting an agent does not swap one
/// control for another: the bar moves down the pane and the conversation appears above
/// it, which is why this is one view rather than a start form and a composer.
struct PromptBar: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRequests.self) private var requests
    @Environment(\.chatActions) private var chatActions
    /// Whether the folder is the caller's to decide rather than this bar's.
    ///
    /// Set on a project page, where the folder is the project and changing it would
    /// start the agent under a different one.
    var folderIsFixed = false
    @State private var text = ""
    @State private var selectedCommand = 0
    @State private var attachments: [Attachment] = []
    @State private var draftLabels: [String] = []
    @State private var mentions: [FileMention] = []
    /// The walk for the term typed so far. Each keystroke cancels the last.
    @State private var mentionSearch: Task<Void, Never>?
    @State private var selectedMention = 0
    @State private var dismissedMentionTerm: String?
    /// Set when the list is dismissed, so Escape hides it until the word changes.
    @State private var dismissedCommandTerm: String?
    /// Whether Escape has put the agent's suggestion away for this turn.
    @State private var dismissedSuggestions = false
    @State private var isShowingRuntimeAccount = false
    @State private var isShowingSessions = false
    @State private var isShowingReach = false
    /// How wide the options row has to fill. Read from the row's own width, which the
    /// pane sets and its contents never do — see `optionsRow` for why that direction
    /// matters.
    @State private var optionsWidth: CGFloat = 0
    @FocusState private var focused: Bool
    /// A draft came back without something it held by value — a pasted picture too large
    /// to keep — and the bar says so until the next thing is sent (025 US5).
    @State private var draftLostSomething = false
    /// Prompts this bar has sent that the host has not yet taken (#87). The send button
    /// spins meanwhile; past a beat, the bar says so in words too.
    @State private var sending = 0
    @State private var sendingIsSlow = false

    private var agent: Agent? { model.selectedAgent }
    private var isNew: Bool { agent == nil }

    /// Which conversation the words in this bar belong to, and are kept against. A project
    /// page's bar is that project's; the chat's is its agent's.
    private var draftKey: DraftKey {
        if let agent { return .agent(agent.id) }
        return .newAgent(folder: folderIsFixed ? model.selectedProject : nil)
    }

    // MARK: What the agent thinks you might ask

    /// What the agent offered, of which there is one (031).
    ///
    /// Only while the field is empty: half a typed thought is already the answer to
    /// what was suggested, and a suggestion sitting behind it would be noise. Only
    /// while no list is up, because Tab belongs to the list then.
    private var suggestion: SuggestedPrompt? {
        guard let agent, !dismissedSuggestions, text.isEmpty, !isCompleting, !isMentioning else {
            return nil
        }
        return agent.suggestedPrompts.first
    }

    /// Take the words. They land in the field rather than going: the agent wrote
    /// them, and sending them is still the user's move.
    private func takeFocusIfAsked() {
        guard requests.wantsPromptFocus, folderIsFixed else { return }
        requests.wantsPromptFocus = false
        // After the page has settled: from inside a chat, this bar is already there under
        // the chat, and focus asked for before the chat has popped off it lands nowhere.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true }
    }

    private func takeSuggestion() {
        guard let suggestion else { return }
        text = suggestion.prompt
        focused = true
    }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                whereAndWhat
                atItsLimit
                startingOnOut
                if !attachments.isEmpty {
                    AttachmentStrip(attachments: attachments,
                                    refusal: { $0.refusal(from: model.promptCapabilities) },
                                    remove: { attachment in
                                        attachments.removeAll { $0.id == attachment.id }
                                    })
                }
                if draftLostSomething {
                    Text(PromptWords.draftLostSomething)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
                if isCompleting {
                    CommandList(commands: matchingCommands, selected: selectedCommand,
                                choose: accept)
                        .transition(.opacity)
                }
                if isMentioning {
                    MentionList(mentions: mentions, selected: selectedMention, choose: accept)
                        .transition(.opacity)
                }
                if agent == nil, let refusal = model.draftSandboxRefusal {
                    sandboxRefusal(refusal)
                }
                // On its way (#87): a start can take seconds, making a worktree and a
                // runtime, and a send to a slow host as long.
                if agent == nil, model.isStarting {
                    Telling(host: recipient, doing: AgentState.startingLabel)
                } else if agent != nil, sending > 0, sendingIsSlow {
                    Telling(host: recipient, doing: "Sending")
                }
                field
                options
            }
        }
        // A send is usually back before anyone could read a word; the spinner in the
        // button is enough for that. Words only for one still going after a beat.
        .task(id: sending > 0) {
            sendingIsSlow = false
            guard sending > 0 else { return }
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { sendingIsSlow = true }
        }
        // The same column the transcript draws in, so the bar's edges track its edges
        // at every width (FR-021).
        .chatColumn()
        .padding(.vertical, 20)
        .sheet(isPresented: $isShowingRuntimeAccount) {
            if let runtimeID = agent?.runtimeID ?? model.draftRuntimeID {
                RuntimeAccountView(runtimeID: runtimeID)
                    .paperSheet()
            }
        }
        .sheet(isPresented: $isShowingSessions) {
            if let runtimeID = model.draftRuntimeID, let cwd = model.draftCwd {
                SessionListView(runtimeID: runtimeID, cwd: cwd)
                    .paperSheet()
            }
        }
        .sheet(isPresented: $isShowingReach) {
            AgentReachView(cwd: model.draftCwd,
                           folders: Binding(get: { model.draftFolders },
                                            set: { model.draftFolders = $0 }),
                           servers: Binding(get: { model.draftServers },
                                            set: { model.draftServers = $0 }))
                .paperSheet()
        }
        .onChange(of: model.selection) {
            dismissedSuggestions = false
            // What was half typed is no longer thrown away here. It is kept against the
            // conversation it was typed for, and each conversation's own comes back, files
            // and all — see `KeepsDrafts`. Words meant for one agent still never reach
            // the next: the bar only ever holds what belongs to where it is.
        }
        // File ▸ New Session: the keyboard goes where the session starts, the project
        // page's bar. The chat's own bar, on its way out, has no agent by then either,
        // so it is told apart by being the one whose folder is not fixed.
        .onChange(of: requests.wantsPromptFocus, initial: true) { takeFocusIfAsked() }
        // Opened: its runtime starts now, so the reply does not wait for it (#183). Once
        // it has been on screen a moment, so arrowing past chats starts nothing (#202).
        .task(id: agent?.id) {
            guard let id = agent?.id else { return }
            try? await Task.sleep(for: DaemonAPI.PrewarmRequest.openedAfter)
            guard !Task.isCancelled else { return }
            await model.prewarm(id, .opened)
        }
        // Words offered from elsewhere on the page. They land in the field, focused
        // and unsent, the same as a suggestion taken with Tab.
        .onChange(of: model.offeredPrompt) {
            guard let offered = model.offeredPrompt else { return }
            text = offered
            focused = true
            model.offeredPrompt = nil
        }
        // A new one is a new turn's worth, so it comes back from having been dismissed.
        .onChange(of: agent?.suggestedPrompts ?? []) {
            dismissedSuggestions = false
        }
        .onAppear { prepare() }
        .onChange(of: model.availableRuntimes.map(\.id)) { prepare() }
        // Until a folder is chosen, the first agent to arrive names it. After that,
        // another project's agent arriving is not a reason to list this one's
        // worktrees again (#285).
        .onChange(of: model.work.agentCount) {
            guard isNew, model.draftCwd == nil else { return }
            prepare()
        }
        .onChange(of: draftProjectAgentCount) {
            guard isNew, model.draftCwd != nil else { return }
            Task { await model.loadDraftWorktrees() }
        }
        .modifier(KeepsDrafts(text: $text, attachments: $attachments,
                              lostSomething: $draftLostSomething, key: draftKey))
    }

    // MARK: A limit reached

    /// Said above the field when the open agent may take no more prompts, with
    /// exactly two ways out: raise the limit, or let this one agent go on.
    ///
    /// Neither happens without the reader choosing it and neither is the default.
    /// Nothing here sends a prompt — raising a ceiling makes an agent promptable
    /// again; continuing is the reader's second act, deliberately.
    @ViewBuilder
    private var atItsLimit: some View {
        // The phone's too (033). Only the way to raise it is the Mac's own.
        if let agent {
            CostLimitBanner(agent: agent, limits: model.costLimits, costState: model.costState,
                            goOn: { Task { await model.letThisAgentGoOn(agent) } }) {
                SettingsLink { Text("Raise the limit") }
                    .buttonStyle(.paper)
                    .appText(.fine)
            }
        }
    }

    /// A new chat about to start on a runtime that is out (052, US3; 065): said before
    /// the first prompt, and only said. Send still sends; there is no other runtime to
    /// offer, since there is no order to take one from.
    @ViewBuilder
    private var startingOnOut: some View {
        if agent == nil, let runtimeID = model.draftRuntimeID,
           let sentence = model.runtimeAllowances?.startingOnOut(runtimeID) {
            Text(sentence)
                .appText(.fine)
                .foregroundStyle(StateTint.attention.style(or: .primary))
        }
    }

    // MARK: The folder, and what runs in it

    /// What a row over the prompt does on a Mac (057): Stop, the subagent's steps in
    /// the sidebar, and the output in TextEdit.
    private func backgroundActions(_ agent: Agent) -> BackgroundActions {
        BackgroundActions(
            stop: { [model] item in await model.stopBackground(item, of: agent.id) },
            steps: { [chatActions] item in chatActions.subagentSteps?(item.id) },
            output: { [model] item in Task { await BackgroundOutput.open(item, of: agent, model: model) } })
    }

    private var whereAndWhat: some View {
        // Top for a chat, so its runtime sits level with the first line however tall the
        // header grows; the new chat's row of controls stays centred.
        HStack(alignment: agent == nil ? .center : .top, spacing: 12) {
            if let agent {
                VStack(alignment: .leading, spacing: 8) {
                    // Where it works, and the way to move it (053), with its labels
                    // beside it, as a new session has them beside its folder and reach.
                    HStack(alignment: .top, spacing: 12) {
                        if let place = agentPlace(agent) {
                            place
                        }
                        SessionLabelEditor(agent: agent)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                PromptHeader(agent: agent,
                             leaseStatus: model.work.leaseStatus(of: agent.id),
                             openLease: { model.showResources(at: $0) },
                             waitStatus: agent.eventWait?.isOpen == true ? model.work.waitStatus(of: agent) : nil,
                             waitHint: agent.eventWait.map(EventWords.hint) ?? "",
                             openWait: { model.showEvents(at: .waitingNow) },
                             cancelWait: { Task { await model.cancelWait(of: agent.id) } },
                             background: agent.background,
                             backgroundActions: backgroundActions(agent))
                }
                .task(id: "\(agent.id)-\(agent.cwd.path)") { await model.loadAgentWorktrees(of: agent) }
                Spacer(minLength: 0)
                runtimeLabel(agent)
            } else {
                // On a project page the folder is the project, named in the middle of
                // the page; only a session with no project yet chooses one.
                if !folderIsFixed {
                    Button(action: chooseFolder) {
                        HStack(spacing: 5) {
                            Image(systemName: "folder")
                            // The folder's own name. The path it sits under is rarely the
                            // thing you are checking, and it is in the tooltip when it is.
                            Text(model.draftCwd?.lastPathComponent ?? "Choose a folder")
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.paper)
                    .appText(.fine)
                    .help(folderHelp)
                }

                if model.draftWorktrees.isRepository {
                    worktreeChooser
                }
                reachButton
                labelDraft
                    .fixedSize(horizontal: true, vertical: false)

                Spacer(minLength: 8)

                // What else this runtime is holding in this folder, including work
                // started somewhere else entirely.
                Button {
                    isShowingSessions = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.paper)
                .appText(.fine)
                .disabled(model.draftCwd == nil || model.draftRuntimeID == nil)
                .help("Conversations this runtime is already holding here")
                .accessibilityLabel("Sessions")

                SelectCapsule(name: "Runtime",
                              title: model.draftRuntimeID.map(runtimeName) ?? "Runtime") { dismiss in
                    ScrollingChoices {
                        if !outRuntimes.isEmpty {
                            SelectGroupHeading(title: "Available")
                        }
                        ForEach(availableRuntimes) { status in
                            SelectChoice(title: status.runtime.name,
                                         description: availableNote(status.runtime.id) ?? signInNote(status.runtime.id),
                                         isChosen: status.runtime.id == model.draftRuntimeID) {
                                chooseRuntime(status.runtime.id)
                                dismiss()
                            }
                        }
                        if !outRuntimes.isEmpty {
                            Divider().padding(.vertical, 4)
                            SelectGroupHeading(title: "Out")
                            ForEach(outRuntimes) { status in
                                SelectChoice(title: status.runtime.name,
                                             description: outNote(status.runtime.id),
                                             isChosen: status.runtime.id == model.draftRuntimeID) {
                                    chooseRuntime(status.runtime.id)
                                    dismiss()
                                }
                            }
                        }
                    }
                    Divider().padding(.vertical, 4)
                    SelectChoice(title: "Sign in, sign out, providers…",
                                 description: nil,
                                 isChosen: false) {
                        dismiss()
                        isShowingRuntimeAccount = true
                    }
                }
                .disabled(model.availableRuntimes.isEmpty)
                .help(noServerRuntime ?? "")
            }
        }
    }

    /// The runtime the conversation is on, where a new chat chooses one. Said, not
    /// offered: a conversation stays on the runtime it started on.
    private func runtimeLabel(_ agent: Agent) -> some View {
        Text(runtimeName(agent.runtimeID))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .appText(.fine)
            .fixedSize()
            .paperRaised(in: .capsule)
            .help("Runtime")
            .accessibilityLabel("Runtime: \(runtimeName(agent.runtimeID))")
    }

    /// A server with nothing to start agents with says so where the runtime is chosen
    /// (037, FR-012).
    private var noServerRuntime: String? {
        let host = model.selectedProjectHost
        guard agent == nil, host != .mac, !model.hosts.isOffline(host), model.availableRuntimes.isEmpty else { return nil }
        let label = model.hosts.label(host)
        return "No agent runtime on \(label). Install one there and log in, then choose Check again."
    }

    // MARK: What you want done

    private var field: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .appText(.reading)
                .lineLimit(2...12)
                .focused($focused)
                // ⌘V attaches pictures and files too, and still pastes the words (#396).
                .modifier(PastesIntoPrompt(isFocused: focused, attachFile: attach,
                                           attachPicture: attachPicture))
                // Held, words and all, while they start an agent (#87).
                .disabled(agent == nil && model.isStarting)
                // Return and Shift-Return send. Option and Return is left alone, and
                // the field editor inserts a line break the way it does everywhere else
                // (#377).
                .onKeyPress(.return, phases: .down) { press in
                    guard PromptReturn(option: press.modifiers.contains(.option)) == .send else { return .ignored }
                    // While the list is up, Return takes the command rather than
                    // sending a half-typed one.
                    if isCompleting || isMentioning {
                        acceptSelected()
                    } else {
                        send()
                    }
                    return .handled
                }
                .onKeyPress(.tab) {
                    if isCompleting || isMentioning {
                        acceptSelected()
                        return .handled
                    }
                    // Tab takes what is being offered, the way it does everywhere else
                    // something is written ahead of you.
                    guard suggestion != nil else { return .ignored }
                    takeSuggestion()
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
                    // Put it away, and it stays away until the next turn ends.
                    guard suggestion != nil else { return .ignored }
                    dismissedSuggestions = true
                    return .handled
                }
                .onChange(of: text) {
                    selectedCommand = 0
                    selectedMention = 0
                    if dismissedCommandTerm != commandQuery?.term { dismissedCommandTerm = nil }
                    if dismissedMentionTerm != mentionQuery?.term { dismissedMentionTerm = nil }
                    updateMentions()
                    // Typing is a prompt coming (#183).
                    if !text.isEmpty, let id = agent?.id { Task { await model.prewarm(id, .typing) } }
                }

            Button(action: chooseAttachment) {
                Image(systemName: "paperclip")
                    .appText(.reading).fontWeight(.semibold)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.paper)
            .buttonBorderShape(.circle)
            .help("Attach a file or a picture")
            .accessibilityLabel("Attach")

            Button(action: dictate) {
                Image(systemName: "microphone")
                    .appText(.reading).fontWeight(.semibold)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.paper)
            .buttonBorderShape(.circle)
            .help("Dictate, as the Mac does everywhere")
            .accessibilityLabel("Dictate")

            // While it works and nothing is typed, send is stop. Type and it is send
            // again, queueing what is typed for when the turn ends.
            if let agent, model.canStop(agent), text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               sending == 0 {
                let acting = model.acting(agent.id)
                Button {
                    Task { await model.stop(agent.id) }
                } label: {
                    Group {
                        if acting == .stop {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: PromptWords.stopSymbol)
                                .appText(.reading).fontWeight(.semibold)
                        }
                    }
                    .frame(width: 22, height: 22)
                }
                .buttonStyle(.paperProminent)
                .buttonBorderShape(.circle)
                // Held while something else is on its way to this agent. Not while it is Stop:.
                // the one that went stays bright, as on the answer cards (#86), and the
                // model refuses a second press.
                .disabled(acting != nil && acting != .stop)
                .help(acting == .stop ? Telling.words(doing: "Stopping", host: recipient) : PromptWords.stopHelp)
                .accessibilityLabel("Stop")
                .accessibilityValue(acting == .stop ? Telling.words(doing: "Stopping", host: recipient) : "")
            } else {
                Button(action: send) {
                    Group {
                        if isGoing {
                            ProgressView().controlSize(.small)
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
                .disabled(!canSend && !isGoing)
                .keyboardShortcut(.return, modifiers: .command)
                .help(targetOffline ? model.offlineHelp(for: targetHost)
                                    : PromptWords.sendHelp(willQueue: willQueue))
                .accessibilityLabel(PromptWords.sendLabel(willQueue: willQueue))
            }
        }
        .padding(14)
        .paperRaised(in: RoundedRectangle(cornerRadius: 18))
        // A file dragged onto the prompt is a file you are talking about.
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls { attach(url) }
            return !urls.isEmpty
        }
        .onPasteCommand(of: [.fileURL] + PromptPaste.pictureTypes + [.image]) { providers in
            for provider in providers { paste(provider) }
        }
    }

    // MARK: Said instead of typed

    /// The Mac's own dictation, in this field (#427).
    ///
    /// It is the same thing pressing the dictation key starts. It writes at the cursor,
    /// underlines what it is still unsure of, and lets the person type and edit while it
    /// listens. A recogniser of our own would only be a worse copy of it. The system
    /// shows its own microphone and stops it the usual ways, and asks for nothing more
    /// than its own switch in Keyboard settings.
    private func dictate() {
        focused = true
        // Once the field has focus, so the field editor is the one that listens.
        DispatchQueue.main.async {
            NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
        }
    }

    // MARK: What goes with the words

    private func chooseAttachment() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { attach(url) }
    }

    /// A picture goes by value where the runtime takes pictures; everything else goes
    /// as a reference, which every runtime takes.
    private func attach(_ url: URL) {
        let isImage = ["png", "jpg", "jpeg", "gif", "heic", "webp"].contains(url.pathExtension.lowercased())
        if isImage, model.promptCapabilities.allows(.image), let data = try? Data(contentsOf: url) {  // store-ok: a file the person picked or dropped
            attachments.append(.image(data, mimeType: mimeType(for: url), name: url.lastPathComponent))
        } else {
            attachments.append(.file(url))
        }
    }

    private func paste(_ provider: NSItemProvider) {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in attach(url) }
            }
            return
        }
        guard case .picture(let type) = PromptPaste.kind(of: provider.registeredTypeIdentifiers) else { return }
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data else { return }
            Task { @MainActor in attachPicture(data, type) }
        }
    }

    /// A pasted picture, by value. A runtime that takes none says so in red under it.
    private func attachPicture(_ data: Data, _ type: UTType) {
        let name = type == .png || type == .tiff ? "Screenshot" : "Pasted picture"
        attachments.append(.image(data, mimeType: PromptPaste.mimeType(for: type), name: name))
    }

    private func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    // MARK: Files named with an @

    private var mentionFolders: [URL] {
        if let agent { return [agent.cwd] + agent.additionalDirectories }
        return model.draftCwd.map { [$0] } ?? []
    }

    private var mentionQuery: MentionQuery? {
        FileMention.query(in: text)
    }

    private var isMentioning: Bool {
        guard let mentionQuery, !mentions.isEmpty else { return false }
        return dismissedMentionTerm != mentionQuery.term
    }

    private func updateMentions() {
        mentionSearch?.cancel()
        guard let mentionQuery, !mentionFolders.isEmpty else {
            mentions = []
            return
        }
        // Walking a repository on every keystroke is the thing to avoid, so this is
        // capped in the kit and only runs once there is something to match on.
        guard mentionQuery.term.count >= 1 else {
            mentions = []
            return
        }
        // Off the main actor, because even the capped walk is twenty thousand stat
        // calls, and the field must take the next character while it runs. What was
        // typed since is the search that matters, so the walk is cancelled by it.
        let term = mentionQuery.term
        let folders = mentionFolders
        mentionSearch = Task {
            let found = await Task.detached(priority: .userInitiated) {
                FileMention.matching(term, in: folders)
            }.value
            guard !Task.isCancelled else { return }
            mentions = found
        }
    }

    private func accept(_ mention: FileMention) {
        guard let mentionQuery else { return }
        text = mention.completing(mentionQuery, in: text)
        attachments.append(.file(mention.url))
        mentions = []
        selectedMention = 0
    }

    // MARK: What the runtime takes after a slash

    private var availableCommands: [SlashCommand] {
        agent?.availableCommands ?? model.draftCommands
    }

    private var commandQuery: SlashQuery? {
        SlashCommand.query(in: text)
    }

    private var matchingCommands: [SlashCommand] {
        guard let commandQuery else { return [] }
        return SlashCommand.matching(commandQuery.term, in: availableCommands)
    }

    private var isCompleting: Bool {
        guard commandQuery != nil, !matchingCommands.isEmpty else { return false }
        return dismissedCommandTerm != commandQuery?.term
    }

    private func acceptSelected() {
        if isMentioning, mentions.indices.contains(selectedMention) {
            accept(mentions[selectedMention])
            return
        }
        guard matchingCommands.indices.contains(selectedCommand) else { return }
        accept(matchingCommands[selectedCommand])
    }

    private func accept(_ command: SlashCommand) {
        guard let commandQuery else { return }
        text = command.completing(commandQuery, in: text)
        selectedCommand = 0
    }

    private var placeholder: String {
        // What the agent thinks you might ask, written where the answer goes. It is
        // the placeholder rather than anything drawn over the field: the field has
        // one text style and one origin, and this way the words sit in it exactly as
        // the typed ones will.
        if let suggestion { return suggestion.prompt }
        guard let agent else { return PromptWords.askPlaceholder }
        return PromptWords.placeholder(for: agent)
    }

    // MARK: Whatever this runtime offers

    /// What the area under the prompt is showing, which is never nothing.
    ///
    /// Six ways to have no controls, and each one now says which it is. This used to be
    /// an `if` with no `else`, so a runtime that advertises nothing, a fetch that
    /// failed and a folder not yet chosen were all the same silent gap.
    @ViewBuilder
    private var options: some View {
        if case .controls(let shown) = controlsState {
            optionsRow(shown)
        } else {
            // The same sentences the phone says (033).
            OptionsNote(state: controlsState, retry: { Task { await model.loadDraftOptions() } })
        }
    }

    /// What the window knows, turned into the one thing the row shows.
    private var controlsState: PromptControlsState {
        PromptControlsState.resolve(
            agentOptions: agent.map(\.advertisedOptions),
            // An agent's own, never the new-chat form's: those may be another
            // runtime's, and a choice made on one would be sent to this agent. The
            // phone has always passed none here.
            draftOptions: agent == nil ? model.draftOptions : [],
            // Both are settled facts about an agent that exists, which is why
            // `whereAndWhat` draws them as labels rather than controls.
            hasFolder: agent != nil || model.draftCwd != nil,
            hasRuntime: agent != nil || model.draftRuntimeID != nil,
            runtimeName: (agent?.runtimeID ?? model.draftRuntimeID).map(runtimeName),
            // Only a draft fetches. An agent's options came with it.
            isLoading: agent == nil && model.isLoadingDraftOptions,
            failure: agent == nil ? model.draftOptionsFailure : nil)
    }

    /// What the agent is allowed to do first, how well it does it after: permissions on
    /// the left, and the model, its thinking and its speed on the right.
    ///
    /// It scrolls sideways. The row is wider than this pane at every window size the
    /// app allows below about 693 points, and a scroll view reads its content's ideal
    /// width without feeding a decision back into it. Anything that measures the width
    /// and picks a layout from it can re-measure what it just changed, and AppKit kills
    /// the app when that loop reaches the window: first a custom Layout did it, then
    /// ViewThatFits did it intermittently.
    ///
    /// A spacer inside a horizontal scroll view has no width to take, so the right-hand
    /// controls are pushed over by giving the row a floor to fill: the width of the
    /// scroll view itself. That is safe where measuring the content is not, because the
    /// scroll view fills whatever the pane offers whatever is inside it, so nothing
    /// here can change the number it was told. Narrower than the floor and the spacer
    /// takes the slack; wider and the floor does nothing and the row scrolls as before.
    private func optionsRow(_ shown: [ConfigOption]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                permissionOptions(shown)
                sandboxCapsule(shown)
                Spacer(minLength: 16)
                otherOptions(shown)
                // What it has used, beside how it thinks.
                if let agent {
                    ContextMeter(agent: agent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .paperRaised(in: Capsule())
                }
            }
            // The raised capsules are drawn to their own edge, and a scroll view clips
            // at its bounds. A point either side keeps their edge and shadow from being shaved.
            .padding(.vertical, 1)
            .frame(minWidth: optionsWidth, alignment: .leading)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The visible width as the scroll view itself has it, rather than the width of
        // its frame from outside: the frame came back some twenty points wider or
        // narrower than what is shown, and the right-hand controls stopped that far
        // short of the prompt's edge.
        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.width } action: { _, width in
            optionsWidth = width
        }
    }

    /// The permission mode, as its value alone: it is the leftmost pill, and that is
    /// what it is.
    /// Folders and MCP servers a new agent may reach, beside where it starts.
    private var reachButton: some View {
        Button {
            isShowingReach = true
        } label: {
            HStack(spacing: 4) {
                Text(reachTitle)
                Image(systemName: "chevron.down")
                    // Decorative: a glyph in a capsule, not text (FR-015).
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .appText(.fine)
        .fixedSize()
        .paperRaised(in: .capsule)
        .help("Folders and MCP servers this agent may reach")
    }

    @ViewBuilder
    private func permissionOptions(_ shown: [ConfigOption]) -> some View {
        ForEach(shown.filter(\.isAboutPermission)) { option in
            OptionMenu(option: option, chosen: binding(for: option))
        }
    }

    /// The command sandbox, beside the mode it is so often mistaken for (064, FR-004).
    @ViewBuilder
    private func sandboxCapsule(_ shown: [ConfigOption]) -> some View {
        if let runtimeID = agent?.runtimeID ?? model.draftRuntimeID {
            let mode = shown.first { $0.id == "mode" }.flatMap { binding(for: $0).wrappedValue?.stringValue }
            SandboxCapsule(runtimeID: runtimeID,
                           override: agent == nil ? model.draftSandbox : agent?.sandboxOverride,
                           runtimeDefault: model.sandboxSettings.choice(for: runtimeID),
                           codexMode: mode,
                           effective: agent?.effectiveSandbox,
                           isWorking: agent?.state == .running) { choice in
                if let agent {
                    Task { await model.setAgentSandbox(agent.id, choice) }
                } else {
                    model.draftSandbox = choice
                    // Codex's sandbox is its mode (FR-005a): the draft's mode follows.
                    if runtimeID == RuntimeCatalog.codex.id, let option = shown.first(where: { $0.id == "mode" }) {
                        switch choice {
                        case .off: model.draftChosen[option.id] = .string("agent-full-access")
                        case .on where mode == "agent-full-access": model.draftChosen[option.id] = .string("read-only")
                        default: break
                        }
                    }
                }
            }
        }
    }

    /// Everything else as one pill: the model, its effort and fast mode.
    @ViewBuilder
    private func otherOptions(_ shown: [ConfigOption]) -> some View {
        let others = shown.filter { !$0.isAboutPermission }
        if !others.isEmpty {
            ModelPill(options: others, binding: binding(for:))
        }
    }

    /// A choice goes to the draft before there is an agent, and to the daemon after.
    ///
    /// Both branches now write somewhere the getter reads. The draft one always did,
    /// which is why a new chat was already instant; the agent one wrote only to a
    /// `Task`, so the control kept showing the old value for the whole round trip.
    private func binding(for option: ConfigOption) -> Binding<JSONValue?> {
        Binding(
            get: {
                if let agent {
                    return model.chosenOption(option.id, for: agent, advertised: option)
                }
                return model.draftChosen[option.id] ?? option.currentValue
            },
            set: { value in
                guard let value else { return }
                // The mode is remembered by the daemon now: on a live conversation's
                // change, and on the start a draft's choice becomes (029).
                if let agent {
                    // Synchronous: it writes the optimistic value now and sends in the
                    // background, so the control changes as the menu closes.
                    model.setOption(agentID: agent.id, optionID: option.id, value: value)
                } else {
                    model.draftChosen[option.id] = value
                }
            })
    }

    // MARK: Doing it

    /// An agent that is working is not a reason to refuse. The daemon holds what is
    /// typed and sends it when the turn ends, which is what the queue below the
    /// prompt is showing.
    /// The machine this prompt would go to (037).
    private var targetHost: HostID { agent?.host ?? model.selectedProjectHost }
    private var targetOffline: Bool { model.hosts.isOffline(targetHost) }

    /// Who the prompt goes to, as the pending mark says it.
    private var recipient: String {
        if let agent { return model.answerRecipient(agent.id) }
        return targetHost == .mac ? "your Mac" : model.hosts.label(targetHost)
    }

    /// Something from this bar is on its way: the agent being started, or a prompt.
    private var isGoing: Bool { agent == nil ? model.isStarting : sending > 0 }

    private var canSend: Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // One new agent at a time: a second Return is not a second agent (#87).
        if agent == nil, model.isStarting { return false }
        // Kept in the field, never sent into nothing.
        guard !targetOffline else { return false }
        if agent != nil { return true }
        return model.draftCwd != nil && model.draftRuntimeID != nil
    }

    /// Whether what is typed now will wait rather than go.
    private var willQueue: Bool {
        guard let agent else { return false }
        return PromptWords.willQueue(agent)
    }

    /// A new agent's runtime would not start because of its sandbox (064): what it said,
    /// and **Start without sandbox**, which sends what is typed again with this agent Off.
    private func sandboxRefusal(_ refusal: DaemonAPI.SandboxWillNotStart) -> some View {
        let name = RuntimeCatalog.runtime(id: refusal.runtimeID)?.name ?? refusal.runtimeID
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SandboxWords.cardTitle(name)).appText(.fine).fontWeight(.semibold)
                Text(refusal.detail.split(separator: "\n").first.map(String.init) ?? "")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(refusal.detail)
            }
            Spacer()
            if refusal.offOffered {
                Button(SandboxWords.startWithout) {
                    model.draftSandbox = .off
                    send()
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(StateTint.attention.color?.opacity(0.07) ?? .clear, in: RoundedRectangle(cornerRadius: 8))
    }

    private var labelDraft: some View {
        LabelTagField(labels: draftLabels.map { SessionLabel(value: $0, owner: .person) },
                      suggestions: model.draftCwd.map { model.labelSuggestions(in: $0, on: model.selectedProjectHost) } ?? [],
                      add: { draftLabels += $0 },
                      remove: { value in draftLabels.removeAll { SessionLabelPolicy.key($0) == SessionLabelPolicy.key(value) } })
            .task(id: model.draftCwd.map { ProjectKey(host: model.selectedProjectHost, folder: $0) }) {
                if let folder = model.draftCwd { await model.loadLabelVocabulary(in: folder, on: model.selectedProjectHost) }
            }
    }

    private func send() {
        guard canSend else { return }
        // Nothing the runtime cannot take is sent, and the prompt is not lost.
        if let refused = attachments.compactMap({ $0.refusal(from: model.promptCapabilities) }).first {
            model.show(problem: refused)
            return
        }
        // Whatever is said next is not part of what went (#318).
        NSApp.sendAction(Selector(("stopDictation:")), to: nil, from: nil)
        let outgoing = text
        let going = attachments
        let labels = draftLabels
        let starting = agent == nil
        // Read now: once started, this bar is the new agent's.
        let key = draftKey
        // A prompt to an agent leaves the field at once, so sending feels immediate:
        // the chat has somewhere to show it. A new agent has no chat yet, so its words
        // stay in the held field, under "Starting — telling your Mac", until it exists
        // (#87).
        if !starting {
            text = ""
            attachments = []
            // A draft exists only until it becomes a prompt. Given back below if it did not go.
            DraftKeeper.shared.clear(draftKey)
        }
        draftLostSomething = false
        // Whatever was suggested has been answered, by being taken or by being typed
        // past. The daemon clears it when the turn begins, but the field empties now,
        // and an emptied field must not offer last turn's words back.
        dismissedSuggestions = true
        // What you just sent is the thing you want to see, so the conversation comes
        // back to its end even if you were reading three screens up.
        model.scrollToEnd()
        Task {
            if starting {
                // Kept in the field if it did not start, with the reason over it.
                guard await model.startDraft(prompt: outgoing, attachments: going, labels: labels) else { return }
                if text == outgoing { text = "" }
                attachments = []
                draftLabels = []
                DraftKeeper.shared.clear(key)
                return
            }
            sending += 1
            let went = await model.send(outgoing, attachments: going)
            sending -= 1
            // The field empties at once so sending feels immediate, but a prompt that
            // did not go is given back rather than lost, unless something new has been
            // typed in the meantime.
            if !went, text.isEmpty, attachments.isEmpty {
                text = outgoing
                attachments = going
            }
        }
    }

    /// What the folder chip says when you hover it. On a project page it says why it
    /// cannot be pressed, rather than looking broken.
    private var folderHelp: String {
        guard let cwd = model.draftCwd else { return "Folder" }
        let path = cwd.path(percentEncoded: false)
        return folderIsFixed ? "This project's folder: \(path)" : "Folder: \(path)"
    }

    /// What an agent can reach beyond its own folder, said in the control itself.
    private var reachTitle: String {
        let folders = model.draftFolders.count
        let servers = model.draftServers.count
        if folders == 0 && servers == 0 { return "Reach: this folder" }
        var parts: [String] = []
        if folders > 0 { parts.append("\(folders + 1) folders") }
        if servers > 0 { parts.append("\(servers) MCP") }
        return "Reach: " + parts.joined(separator: " · ")
    }

    /// Said in the runtime list, so a runtime that cannot be used says why there, and
    /// one that says which account it is using says that ("Claude Max", "Anthropic API key").
    private func signInNote(_ runtimeID: String) -> String? {
        let account = model.accounts[runtimeID]
        if account?.state == .needsSignIn { return "Needs signing in" }
        return account?.signedInAs?.label
    }

    /// The runtimes to pick from, in two runs: those that can take a turn now, and those
    /// whose allowance is spent (065). An out runtime is still here and still pickable,
    /// because a chat on it takes the message and the runtime says no until its plan is
    /// back. Grouping it away would hide the only way back to it once it recovers.
    ///
    /// A server's runtimes are left in one run: the allowance below is the Mac's own, so
    /// splitting by it would label a server's runtime with the Mac's state. Runtimes is
    /// where the Mac's own standing is read.
    private var splitsByAllowance: Bool { model.selectedProjectHost == .mac }

    private var availableRuntimes: [RuntimeStatus] {
        guard splitsByAllowance else { return model.availableRuntimes }
        return model.availableRuntimes.filter { !isOut($0.id) }
    }

    private var outRuntimes: [RuntimeStatus] {
        guard splitsByAllowance else { return [] }
        return model.availableRuntimes.filter { isOut($0.id) }
    }

    private func isOut(_ runtimeID: String) -> Bool {
        model.runtimeAllowances?.isOut(runtimeID) == true
    }

    /// A rate limit is not an out runtime: the runtime can still take a turn, and
    /// `isUsable` says so. It is a throttle, though, and one row in the available run
    /// that says nothing about it reads as no throttle at all. A model out is said the
    /// same way (#140).
    private func availableNote(_ runtimeID: String) -> String? {
        model.runtimeAllowances?.availableNote(for: runtimeID)
    }

    /// What is wrong with it, under the name. It says nothing about another runtime:
    /// there is no order to take one from (065).
    private func outNote(_ runtimeID: String) -> String? {
        model.runtimeAllowances?.note(for: runtimeID)
    }

    private func runtimeName(_ id: String) -> String {
        PromptWords.runtimeName(id)
    }

    /// How many agents the draft's project holds. Moves when that project does, and
    /// not when any other does (#285).
    private var draftProjectAgentCount: Int {
        guard isNew, let folder = model.draftCwd else { return 0 }
        let counts = model.work.counts(in: ProjectKey(host: model.selectedProjectHost, folder: folder))
        return counts.values.reduce(0, +)
    }

    /// Open on the runtime and folder already in use. An empty chooser is a click
    /// asking for something the app knows.
    private func prepare() {
        guard isNew else { return }
        // What was left on the form, before anything fills in a default over it.
        DraftKeeper.shared.putBackStartForm(into: model)
        if model.draftRuntimeID == nil || !model.availableRuntimes.contains(where: { $0.id == model.draftRuntimeID }) {
            // The one rule (#264): what was put back, else the catalog's default, else the first.
            model.draftRuntimeID = model.defaultRuntimeID
        }
        if model.draftCwd == nil { model.draftCwd = model.agents.first?.projectFolder }
        if model.draftCwd != nil, model.draftRuntimeID != nil, model.draftOptions.isEmpty {
            Task { await model.loadDraftOptions() }
        }
        if model.draftCwd != nil { Task { await model.loadDraftWorktrees() } }
    }

    // MARK: Where in the project (030)

    /// Project folder, a new worktree, or one already there. Only on a repository;
    /// only before the agent exists, since where an agent works is settled at its start.
    private var worktreeChooser: some View {
        let listed = model.draftWorktrees
        return SelectCapsule(name: "Worktree", title: worktreeTitle) { dismiss in
            SelectChoice(title: "Project folder",
                         description: listed.projectFolderDescription,
                         isChosen: model.draftWorktree == nil) {
                model.chooseWorktree(nil)
                dismiss()
            }
            SelectChoice(title: "New worktree",
                         description: listed.canMakeNew ? "A new branch from the last commit here"
                                                        : listed.whyNot,
                         isChosen: model.draftWorktree == .new) {
                model.chooseWorktree(.new)
                dismiss()
            }
            .disabled(!listed.canMakeNew)
            let others = listed.worktrees.filter { !$0.isProjectFolder }
            if !others.isEmpty || !listed.branches.isEmpty {
                Divider().padding(.vertical, 4)
                ScrollingChoices {
                    ForEach(others) { worktree in
                        SelectChoice(title: worktree.name,
                                     description: worktreeDescription(worktree),
                                     isChosen: model.draftWorktree == .existing(worktree.root)) {
                            model.chooseWorktree(.existing(worktree.root))
                            dismiss()
                        }
                        .disabled(!worktree.exists)
                    }
                    if !listed.branches.isEmpty {
                        if !others.isEmpty { Divider().padding(.vertical, 4) }
                        Text("New worktree on a branch")
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 4)
                        ForEach(listed.branches) { branch in
                            SelectChoice(title: branch.name,
                                         description: branch.remote.map { "From \($0)" },
                                         isChosen: chosenBranch == branch.name) {
                                model.chooseWorktree(.branch(branch.name))
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Moving an agent that is already working (053)

    /// The Worktree choice on an agent's page, where the header names its place: where it
    /// works now, and every other place in the project it could move to. Only for an agent
    /// on this Mac, in a repository; anywhere else the header keeps its label.
    private func agentPlace(_ agent: Agent) -> AnyView? {
        guard agent.host == .mac, agent.state != .archived,
              let listed = model.agentWorktrees[agent.projectFolder], listed.isRepository else { return nil }
        // Shown but not opened on a runtime that would forget its conversation in another
        // folder (053), with the reason where the pointer finds it.
        guard RuntimeCatalog.canMoveFolders(runtimeID: agent.runtimeID) else {
            return AnyView(SelectCapsule(name: "Worktree", title: placeTitle(agent, listed)) { _ in EmptyView() }
                .disabled(true)
                .help(RuntimeCatalog.whyCannotMoveFolders(runtimeID: agent.runtimeID)))
        }
        let here = agent.worktree?.root.resolvingSymlinksInPath().path
        let waiting = agent.pendingMove
        return AnyView(VStack(alignment: .leading, spacing: 4) {
            SelectCapsule(name: "Worktree", title: placeTitle(agent, listed)) { dismiss in
                SelectChoice(title: "Project folder",
                             description: listed.projectFolderDescription,
                             isChosen: waiting == nil ? here == nil : waiting?.target == .projectFolder) {
                    Task { await model.move(agent, to: .projectFolder) }
                    dismiss()
                }
                SelectChoice(title: "New worktree",
                             description: listed.canMakeNew ? "A new branch from the last commit where it is now"
                                                            : listed.whyNot,
                             isChosen: { if case .newWorktree = waiting?.target { return true }; return false }()) {
                    Task { await model.move(agent, to: .newWorktree(name: nil)) }
                    dismiss()
                }
                .disabled(!listed.canMakeNew)
                let others = listed.worktrees.filter { !$0.isProjectFolder }
                if !others.isEmpty {
                    Divider().padding(.vertical, 4)
                    ScrollingChoices {
                        ForEach(others) { worktree in
                            SelectChoice(title: worktree.name,
                                         description: worktreeDescription(worktree),
                                         isChosen: waiting == nil
                                            ? worktree.root.resolvingSymlinksInPath().path == here
                                            : waiting?.target == .existing(worktree.root)) {
                                Task { await model.move(agent, to: .existing(worktree.root)) }
                                dismiss()
                            }
                            .disabled(!worktree.exists)
                        }
                    }
                }
                if waiting != nil {
                    Divider().padding(.vertical, 4)
                    SelectChoice(title: "Cancel move",
                                 description: "Stay where it is when this turn ends",
                                 isChosen: false) {
                        Task { await model.move(agent, to: nil) }
                        dismiss()
                    }
                }
            }
            .help(waiting == nil ? agent.cwd.path(percentEncoded: false)
                                 : "Moves when this turn ends. \(agent.cwd.path(percentEncoded: false))")
            if let problem = model.moveProblems[agent.id] {
                Text(problem)
                    .appText(.fine)
                    .tinted(.failure)
                    .lineLimit(3)
                    .frame(maxWidth: 360, alignment: .leading)
            }
        })
    }

    /// Where it works, or where it is going once this turn is over.
    private func placeTitle(_ agent: Agent, _ listed: DaemonAPI.WorktreesListResponse) -> String {
        if let waiting = agent.pendingMove {
            switch waiting.target {
            case .projectFolder: return "Moving to project folder…"
            case .newWorktree(let name): return "Moving to \(name ?? "a new worktree")…"
            case .existing(let root): return "Moving to \(root.lastPathComponent)…"
            }
        }
        if let worktree = agent.worktree { return worktree.name }
        return listed.projectFolderBranch ?? "Project folder"
    }

    private var chosenBranch: String? {
        if case .branch(let name) = model.draftWorktree { return name }
        return nil
    }

    /// Its branch and who is in it, so a worktree someone is already working in is
    /// chosen knowing that.
    private func worktreeDescription(_ worktree: DaemonAPI.WorktreeSummary) -> String {
        guard worktree.exists else { return "Missing" }
        let branch = worktree.branch ?? "detached"
        switch worktree.agents.count {
        case 0: return branch
        case 1: return "\(branch) · 1 agent working"
        case let count: return "\(branch) · \(count) agents working"
        }
    }

    private var worktreeTitle: String {
        switch model.draftWorktree {
        case nil: "Project folder"
        case .new: "New worktree"
        case .named(let name): name
        case .existing(let root): root.lastPathComponent
        case .branch(let name): name
        }
    }

    private func chooseRuntime(_ id: String) {
        model.draftRuntimeID = id
        Task { await model.loadDraftOptions() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Work here"
        if panel.runModal() == .OK {
            model.draftCwd = panel.url
            Task { await model.loadDraftOptions() }
        }
    }
}

/// The worktrees and branches in the Worktree chooser, which can outgrow the screen:
/// a repository can have hundreds of branches, so past a height they scroll.
private struct ScrollingChoices<Content: View>: View {
    static var tallest: CGFloat { 320 }

    @ViewBuilder let content: Content

    @State private var contentHeight: CGFloat = 0

    // A popover sizes to what is in it, and a scroll view has no size of its own,
    // so it is given the height of its rows, up to the tallest it may be.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .frame(height: min(contentHeight, Self.tallest))
    }
}
