import AgentsKit
import SwiftUI
import UniformTypeIdentifiers

/// The prompt, and the controls around it.
///
/// The same thing before an agent exists and after. Starting an agent does not swap one
/// control for another: the bar moves down the pane and the conversation appears above
/// it, which is why this is one view rather than a start form and a composer.
struct PromptBar: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var dictation = Dictation()
    @State private var selectedCommand = 0
    @State private var attachments: [Attachment] = []
    @State private var mentions: [FileMention] = []
    @State private var selectedMention = 0
    @State private var dismissedMentionTerm: String?
    /// Set when the list is dismissed, so Escape hides it until the word changes.
    @State private var dismissedCommandTerm: String?
    /// Which of the agent's suggestions is showing, and whether Escape has put them
    /// away for this turn.
    @State private var selectedSuggestion = 0
    @State private var dismissedSuggestions = false
    @State private var isPrimingDictation = false
    @State private var isShowingRuntimeAccount = false
    @State private var isShowingSessions = false
    @State private var isShowingReach = false
    @FocusState private var focused: Bool

    private var agent: Agent? { model.selectedAgent }
    private var isNew: Bool { agent == nil }

    // MARK: What the agent thinks you might ask

    /// The one being offered, of the few the agent sent.
    ///
    /// Only while the field is empty: half a typed thought is already the answer to
    /// what was suggested, and a suggestion sitting behind it would be noise. Only
    /// while no list is up, because Tab and the arrows belong to the list then.
    private var suggestion: SuggestedPrompt? {
        guard let agent, !dismissedSuggestions, text.isEmpty, !isCompleting, !isMentioning else {
            return nil
        }
        let prompts = agent.suggestedPrompts
        guard !prompts.isEmpty else { return nil }
        return prompts[min(selectedSuggestion, prompts.count - 1)]
    }

    /// Take the words. They land in the field rather than going: the agent wrote
    /// them, and sending them is still the user's move.
    private func takeSuggestion() {
        guard let suggestion else { return }
        text = suggestion.prompt
        focused = true
    }

    private func cycleSuggestion(by step: Int) {
        guard let count = agent?.suggestedPrompts.count, count > 0 else { return }
        selectedSuggestion = (selectedSuggestion + step + count) % count
    }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                whereAndWhat
                if !attachments.isEmpty {
                    AttachmentStrip(attachments: attachments,
                                    refusal: { $0.refusal(from: model.promptCapabilities) },
                                    remove: { attachment in
                                        attachments.removeAll { $0.id == attachment.id }
                                    })
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
                field
                options
            }
        }
        .padding(.horizontal, 144)
        .padding(.vertical, 20)
        .sheet(isPresented: $isShowingRuntimeAccount) {
            if let runtimeID = agent?.runtimeID ?? model.draftRuntimeID {
                RuntimeAccountView(runtimeID: runtimeID)
            }
        }
        .sheet(isPresented: $isShowingSessions) {
            if let runtimeID = model.draftRuntimeID, let cwd = model.draftCwd {
                SessionListView(runtimeID: runtimeID, cwd: cwd)
            }
        }
        .sheet(isPresented: $isShowingReach) {
            AgentReachView(cwd: model.draftCwd,
                           folders: Binding(get: { model.draftFolders },
                                            set: { model.draftFolders = $0 }),
                           servers: Binding(get: { model.draftServers },
                                            set: { model.draftServers = $0 }))
        }
        .onChange(of: model.selection) {
            text = ""
            selectedSuggestion = 0
            dismissedSuggestions = false
        }
        // A new set is a new turn's worth, so it starts at the first one and comes
        // back from having been dismissed.
        .onChange(of: agent?.suggestedPrompts ?? []) {
            selectedSuggestion = 0
            dismissedSuggestions = false
        }
        .onAppear { prepare() }
        .onChange(of: model.availableRuntimes.map(\.id)) { prepare() }
        .onChange(of: model.agents.count) { prepare() }
    }

    // MARK: The folder, and what runs in it

    private var whereAndWhat: some View {
        HStack(spacing: 12) {
            if let agent {
                // Both of these are settled once the agent exists, so they are
                // labels rather than controls. They still sit on glass: the
                // transcript scrolls under this row.
                Label(agent.cwd.lastPathComponent, systemImage: "folder")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: Capsule())
                    .help(agent.cwd.path(percentEncoded: false))
                Spacer(minLength: 8)
                ContextMeter(agent: agent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: Capsule())
                Text(runtimeName(agent.runtimeID))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: Capsule())
            } else {
                Button(action: chooseFolder) {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                        // The folder's own name. The path it sits under is rarely the
                        // thing you are checking, and it is in the tooltip when it is.
                        Text(model.draftCwd?.lastPathComponent ?? "Choose a folder")
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.glass)
                .font(.footnote)
                .help(model.draftCwd.map { "Folder: \($0.path(percentEncoded: false))" } ?? "Folder")

                Spacer(minLength: 8)

                // What else this runtime is holding in this folder, including work
                // started somewhere else entirely.
                Button {
                    isShowingSessions = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.glass)
                .font(.footnote)
                .disabled(model.draftCwd == nil || model.draftRuntimeID == nil)
                .help("Conversations this runtime is already holding here")

                SelectCapsule(name: "Runtime",
                              title: model.draftRuntimeID.map(runtimeName) ?? "Runtime") { dismiss in
                    ForEach(model.availableRuntimes) { status in
                        SelectChoice(title: status.runtime.name,
                                     description: signInNote(status.runtime.id),
                                     isChosen: status.runtime.id == model.draftRuntimeID) {
                            chooseRuntime(status.runtime.id)
                            dismiss()
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
            }
        }
    }

    // MARK: What you want done

    private var field: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.title3)
                .lineLimit(2...12)
                .focused($focused)
                // Return sends. Option and Return is left alone, and the field
                // editor inserts a line break the way it does everywhere else.
                .onKeyPress(.return, phases: .down) { press in
                    guard !press.modifiers.contains(.option) else { return .ignored }
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
                    // Nothing typed and something offered: the arrows are how you see
                    // the rest of what the agent thought of. There is no caret to move
                    // in an empty field, so nothing is taken away by this.
                    guard suggestion != nil else { return .ignored }
                    cycleSuggestion(by: 1)
                    return .handled
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
                    guard suggestion != nil else { return .ignored }
                    cycleSuggestion(by: -1)
                    return .handled
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
                    // Put them away, and they stay away until the next turn ends.
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
                }

            Button(action: chooseAttachment) {
                Image(systemName: "paperclip")
                    .font(.headline)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Attach a file or a picture")

            Button(action: toggleDictation) {
                Image(systemName: dictation.isListening ? "waveform" : "microphone")
                    .font(.headline)
                    .frame(width: 22, height: 22)
                    .symbolEffect(.variableColor, isActive: dictation.isListening)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help(dictation.isListening ? "Stop dictating" : "Dictate")

            Button(action: send) {
                Image(systemName: willQueue ? "arrow.up.to.line" : "arrow.up")
                    .font(.headline)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .help(willQueue ? "Queue this, to go when the turn ends" : "Send")
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
        // A file dragged onto the prompt is a file you are talking about.
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls { attach(url) }
            return !urls.isEmpty
        }
        .onPasteCommand(of: [.png, .tiff, .fileURL]) { providers in
            for provider in providers { paste(provider) }
        }
        .sheet(isPresented: $isPrimingDictation) { dictationPrimer }
        .alert("Dictation", isPresented: Binding(get: { dictation.problem != nil },
                                                 set: { if !$0 { dictation.stop() } })) {
            Button("OK") {}
        } message: {
            Text(dictation.problem ?? "")
        }
    }

    /// Our own words before the system's alert, the first time only.
    private var dictationPrimer: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Say it instead of typing it").font(.headline)
            Text("The Mac listens while you hold the button on, and what you say becomes the words in the prompt. It is recognised on this Mac where this Mac can do it.")
                .foregroundStyle(.secondary)
            Text("macOS will ask for the microphone and for speech recognition next.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Not now") { isPrimingDictation = false }
                Button("Continue") {
                    isPrimingDictation = false
                    beginDictation()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

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
        // be spoken over. Dictation keeps hold of it so that stopping and starting
        // again carries on rather than beginning afresh.
        dictation.start(appendingTo: text.trimmingCharacters(in: .whitespacesAndNewlines)) { combined in
            text = combined
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
        if isImage, model.promptCapabilities.allows(.image), let data = try? Data(contentsOf: url) {
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
        for type in [UTType.png, UTType.tiff] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                guard let data else { return }
                Task { @MainActor in
                    attachments.append(.image(data, mimeType: type == .png ? "image/png" : "image/tiff",
                                              name: "Screenshot"))
                }
            }
            return
        }
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
        mentions = FileMention.matching(mentionQuery.term, in: mentionFolders)
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
        guard let agent else { return "Say what you want done" }
        // While it works, the field says what happens to what you type rather than
        // what the agent is doing. The state line in the transcript says that.
        if agent.state.hasTurnInFlight { return "Say what next, and it goes when this turn ends" }
        switch agent.state {
        case .running, .waitingOnUser: return "Say what next"
        case .finished, .stopped: return "Say what next"
        case .archived: return "Say what next, and this comes back"
        }
    }

    // MARK: Whatever this runtime offers

    @ViewBuilder
    private var options: some View {
        let shown = agent?.advertisedOptions.filter(\.isRenderable).sorted { $0.categoryRank < $1.categoryRank }
            ?? model.draftOptions
        if model.isLoadingDraftOptions {
            Text("Asking \(model.draftRuntimeID.map(runtimeName) ?? "the runtime") what it offers…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if !shown.isEmpty {
            // What the agent is allowed to do on the left, how well it does it on the
            // right. Different kinds of decision, so they sit apart.
            //
            // One arrangement, deliberately. Anything that measures the width and
            // picks a layout from it can end up re-measuring what it just changed,
            // and AppKit kills the app when that loop reaches the window: first a
            // custom Layout did it, then ViewThatFits did it intermittently. These
            // are a few short capsules and they fit.
            HStack(spacing: 10) {
                permissionOptions(shown)
                if isNew {
                    Button {
                        isShowingReach = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(reachTitle)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.footnote)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .help("Folders and MCP servers this agent may reach")
                }
                Spacer(minLength: 16)
                otherOptions(shown)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func permissionOptions(_ shown: [ConfigOption]) -> some View {
        ForEach(shown.filter(\.isAboutPermission)) { option in
            OptionMenu(option: option, chosen: binding(for: option))
        }
    }

    @ViewBuilder
    private func otherOptions(_ shown: [ConfigOption]) -> some View {
        ForEach(shown.filter { !$0.isAboutPermission }) { option in
            OptionMenu(option: option, chosen: binding(for: option))
        }
    }

    /// A choice goes to the draft before there is an agent, and to the daemon after.
    private func binding(for option: ConfigOption) -> Binding<JSONValue?> {
        Binding(
            get: {
                if let agent { return agent.startOptions.values[option.id] ?? option.currentValue }
                return model.draftChosen[option.id] ?? option.currentValue
            },
            set: { value in
                guard let value else { return }
                if let agent {
                    Task { await model.setOption(agentID: agent.id, optionID: option.id, value: value) }
                } else {
                    model.draftChosen[option.id] = value
                }
            })
    }

    // MARK: Doing it

    /// An agent that is working is not a reason to refuse. The daemon holds what is
    /// typed and sends it when the turn ends, which is what the queue below the
    /// prompt is showing.
    private var canSend: Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if agent != nil { return true }
        return model.draftCwd != nil && model.draftRuntimeID != nil
    }

    /// Whether what is typed now will wait rather than go.
    private var willQueue: Bool {
        guard let agent else { return false }
        return agent.state.hasTurnInFlight || !agent.queuedPrompts.isEmpty
    }

    private func send() {
        guard canSend else { return }
        // Nothing the runtime cannot take is sent, and the prompt is not lost.
        if let refused = attachments.compactMap({ $0.refusal(from: model.promptCapabilities) }).first {
            model.show(problem: refused)
            return
        }
        dictation.stop()
        let outgoing = text
        let going = attachments
        text = ""
        attachments = []
        Task {
            if agent == nil {
                await model.startDraft(prompt: outgoing, attachments: going)
            } else {
                await model.send(outgoing, attachments: going)
            }
        }
    }

    /// What an agent can reach beyond its own folder, said in the control itself.
    private var reachTitle: String {
        let folders = model.draftFolders.count
        let servers = model.draftServers.count
        if folders == 0 && servers == 0 { return "Reach" }
        var parts: [String] = []
        if folders > 0 { parts.append("\(folders + 1) folders") }
        if servers > 0 { parts.append("\(servers) MCP") }
        return parts.joined(separator: " · ")
    }

    /// Said in the runtime list, so a runtime that cannot be used says why there.
    private func signInNote(_ runtimeID: String) -> String? {
        model.accounts[runtimeID]?.state == .needsSignIn ? "Needs signing in" : nil
    }

    private func runtimeName(_ id: String) -> String {
        RuntimeCatalog.runtime(id: id)?.name ?? id
    }

    /// Open on the runtime and folder already in use. An empty chooser is a click
    /// asking for something the app knows.
    private func prepare() {
        guard isNew else { return }
        if model.draftRuntimeID == nil || !model.availableRuntimes.contains(where: { $0.id == model.draftRuntimeID }) {
            model.draftRuntimeID = model.availableRuntimes.first?.id
        }
        if model.draftCwd == nil { model.draftCwd = model.agents.first?.cwd }
        if model.draftCwd != nil, model.draftRuntimeID != nil, model.draftOptions.isEmpty {
            Task { await model.loadDraftOptions() }
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
