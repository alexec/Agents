import AgentsKitCore
import SwiftUI

/// New session, on a phone: a runtime, what it offers, and what to ask it (029).
///
/// A composer (#4556): the chat's prompt card at the bottom, over the keyboard, with the
/// choices as chips in it above the words, so that with the keyboard up the choices are in
/// view whenever the words are. The rarer ones are behind ⋯, in More. Above the card is
/// only what is not a choice: the project, the persona, kept starts and the Blobs.
///
/// The folder's own page (#366): what its row opens, in the detail rather than a sheet
/// over it, as the Mac's folder row opens its new-session chat. Leaving keeps what was
/// typed. It goes only when the agent it was typed for exists, which is the model's to
/// say, not this view's: by then the page has gone.
struct StartAgentView: View {
    @Environment(RemoteModel.self) private var model
    /// The folder of the scene this is in, when that is a folder's own (#1089).
    @Environment(\.sceneFolder) private var sceneFolder
    /// The folder, with its host: another machine can have one at the same path (#3446).
    let key: FolderKey
    private var folder: URL { key.folder }

    @State private var text = ""
    @State private var attachments: [Attachment] = []
    /// Where the cursor is in `text`, so dictation writes there (#427), as in the chat's bar.
    @State private var selection: TextSelection?
    /// Said instead of typed, as in the chat's bar (#2300).
    @State private var dictation = Dictation()
    @State private var draftLabels: [String] = []
    /// The live pick (#4559, #4721): always on for a new page, until a segment is picked by
    /// hand, and the pick it made from the prompt.
    @State private var personaAuto = true
    @State private var autoPick: Persona.AutoPick?
    /// More is open (#4556); `moreAtLabels` opens it at Labels, from a label's tag.
    @State private var showingMore = false
    @State private var moreAtLabels = false
    /// Why something picked could not be attached, or that a kept picture was too big
    /// to keep and needs picking again.
    @State private var attachNote: String?
    @FocusState private var focused: Bool
    /// Where an iPad's pointer is, for the Blobs to look at while the prompt has focus (#987).
    @State private var pointer: CGPoint?
    /// This showing of the page (#1044): only it lets the page go when it goes.
    @State private var page = UUID()

    var body: some View {
        form
        .onAppear {
            // What it starts opens in this scene (#1089).
            model.composingScene = sceneFolder
            model.startPageAppeared(in: key, page: page)
            let kept = StartDraftKeeper.shared.draft(in: folder)
            text = kept?.text ?? ""
            attachments = kept?.attachments ?? []
            if kept?.droppedInlineData == true {
                // Said rather than restored silently incomplete (025's rule).
                attachNote = "What was attached was too big to keep with the draft. Attach it again."
            }
            // After the kept draft, so a view's prompt is what the field holds (#834).
            takeOffer()
            takeShared()
            focused = true
        }
        .onChange(of: model.offeredStart) { takeOffer() }
        // Share ▸ Agents while this page is already on screen (#4915).
        .onChange(of: model.sharedArrivals) { takeShared() }
        // Voice mode turned on in a chat (another window on an iPad): one listener (#2445).
        .onChange(of: VoiceMode.shared.isOn) { _, isOn in
            if isOn { dictation.stop() }
        }
        // Which showing holds the page is the model's (#2089): the last to come, and the
        // one under it once that goes. But an iPhone says this showing went just after it
        // came, and it stays on screen with nothing behind it: a showing still told of
        // changes takes the page back when nothing holds it. Not one that holds nothing
        // because it is going: the model knows which started their agent. A count, not
        // `startingIn`: that went to the folder and back to nil before a frame was drawn.
        .onChange(of: model.startPageLetGo) {
            model.startPageStillShown(in: key, page: page)
        }
        // Said once, when it arrives: a refusal is the one thing on this page a person
        // using VoiceOver would otherwise have to go looking for.
        .onChange(of: model.startRefusal) {
            if let refusal = model.startRefusal { AccessibilityNotification.Announcement(refusal).post() }
        }
        .onChange(of: attachNote) {
            if let attachNote { AccessibilityNotification.Announcement(attachNote).post() }
        }
        .onChange(of: text) {
            keep()
            // Typed while dictating: theirs, and never written over (#427).
            dictation.edited(text)
            pickAuto()
        }
        // A folder's personas come after its page: Auto reads what the field already holds.
        .onChange(of: model.startPersonas) { pickAuto() }
        .onChange(of: selection) {
            if let range = DictationCursor.range(of: selection, in: text) { dictation.selected(range) }
        }
        .onChange(of: attachments) { keep() }
        // Auto's preview picks a runtime that takes what is attached (#3162).
        .onChange(of: attachments, initial: true) { model.startAttachmentsChanged(attachments) }
        .onDisappear {
            dictation.stop()
            StartDraftKeeper.shared.flush()
            model.startPageDisappeared(page)
        }
    }

    private var form: some View {
        Form {
            // Project, then On (#3279): not in a folder's own scene, which is the folder.
            if sceneFolder == nil { ProjectRows(folder: key) }
            personaHeading
            // Starts kept for this folder's stopped workspace (#691 US3, layouts.md L6a): the
            // agent each makes opens once the host is up.
            if case let starts = model.keptStarts(in: folder), !starts.isEmpty {
                Section {
                    ForEach(starts) { KeptPromptRow(kept: $0) }
                        .listRowBackground(Color.clear)
                }
                .environment(\.chatActions, ChatActions(
                    dropKept: { [model] in await model.dropKept($0) },
                    retryKept: { [model] in await model.retryKept($0) },
                    hostName: { [model] in model.hostName($0) }))
            }
            // A change to the folder's own files that no session can be asked about (#531).
            if model.work.folder(key) != nil {
                ForEach(model.work.guardedChanges(ofFolder: key)) { change in
                    Section {
                        GuardedChangeQuestion(change: change, key: key)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
            }
            // The Blobs (#987) in the space left, last, so with the keyboard up on an iPhone
            // they are what gives way: at the pointer on an iPad with one, else down at the prompt.
            Section {
                Huddle(promptFocused: focused, pointer: pointer, typed: text.count)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
        .paperForm()
        .onContinuousHover(coordinateSpace: .global) { phase in
            if case let .active(location) = phase { pointer = location } else { pointer = nil }
        }
        .navigationTitle(model.work.folder(key)?.name ?? "New session")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HostOfflineStrip(host: model.startHost)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { promptBar.liftsRemoteToasts() }
        .sheet(isPresented: $showingMore) {
            MoreSheet(folder: folder, labels: $draftLabels, atLabels: moreAtLabels)
                .environment(model)
        }
    }

    /// The kind of session to start (#760), at the top of the page as a heading-style menu
    /// (#913), with what the picked one is for, and any persona file that cannot be read,
    /// under it. The folder stays the title. Not drawn where there are none.
    @ViewBuilder private var personaHeading: some View {
        let usable = model.startPersonas.filter { $0.problem == nil }
        let broken = model.startPersonas.filter { $0.problem != nil }
        let picked = usable.first { $0.id == model.startPersona }
        if !model.startPersonas.isEmpty {
            Section {
                VStack(spacing: 4) {
                    if !usable.isEmpty {
                        // Centred under the folder when it fits; a menu of them when it does not (#2795).
                        ViewThatFits(in: .horizontal) {
                            personaPicker(usable, picked: picked)
                            personaPicker(usable, picked: picked, menu: true)
                        }
                    }
                    // What the live pick picked and the word, so the person sees what to change (#4559).
                    if !usable.isEmpty, personaAuto {
                        Text(Persona.autoLine(autoPick))
                            .appText(.supporting)
                            .foregroundStyle(Paper.secondary)
                    }
                    if let description = picked?.description {
                        Text(description)
                            .appText(.supporting)
                            .foregroundStyle(Paper.secondary)
                    }
                    ForEach(broken) { persona in
                        Text("\(persona.id).md: \(persona.problem ?? "")")
                            .appText(.supporting)
                            .foregroundStyle(Paper.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
            .disabled(model.isStarting)
        }
    }

    static let noPersona = "No persona"

    /// Segments, or a menu: the picked one's name and a chevron, where they do not fit (#2795).
    /// No Auto segment (#4721): the prompt's words pick one live until one is picked by hand.
    @ViewBuilder
    private func personaPicker(_ usable: [Persona], picked: Persona?, menu: Bool = false) -> some View {
        let picker = Picker("Persona", selection: Binding<Persona.Segment>(
            get: { Persona.Segment(picked: model.startPersona) },
            set: { segment in
                switch segment {
                case .none: pickPersona(nil)
                case .persona(let id): pickPersona(usable.first { $0.id == id })
                }
            }
        )) {
            Text(Self.noPersona).tag(Persona.Segment.none)
            ForEach(usable) { persona in
                Text(persona.name).tag(Persona.Segment.persona(persona.id))
            }
        }
        let shown = picked?.name ?? Self.noPersona
        if menu {
            picker
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Persona: \(shown)")
        } else {
            picker
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Persona: \(shown)")
        }
    }

    /// Every setting the persona names, and its labels beside any already there, in place
    /// of the last one's (#2649).
    /// A pick by hand sticks for this page (#4559): typing no longer moves it.
    private func pickPersona(_ persona: Persona?, auto: Bool = false) {
        if !auto { personaAuto = false }
        let last = model.startPersonas.first { $0.id == model.startPersona }
        draftLabels = Persona.labels(draftLabels, switchingFrom: last, to: persona)
        Task { await model.choosePersona(persona) }
    }

    /// While the pick is live, the persona the prompt's words name, picked as a hand pick is (#4559).
    private func pickAuto() {
        guard personaAuto else { return }
        let pick = Persona.autoPick(text, among: model.startPersonas)
        autoPick = pick
        if pick?.persona.id != model.startPersona { pickPersona(pick?.persona, auto: true) }
    }

    /// What a view filled the page with (#834): its prompt in the field, unsent, and its
    /// labels beside any already there. Its worktree is the model's to choose.
    private func takeOffer() {
        guard let start = model.takeOfferedStart(in: key) else { return }
        text = start.prompt
        // Held to what a session takes, as a label typed here is.
        draftLabels += SessionLabelPolicy.accepted(start.labels, existing: draftLabels)
        focused = true
    }

    /// What another app shared (#4915): its words after what is typed, its pictures and
    /// files after what is attached, and what the paperclip would refuse said in its words.
    private func takeShared() {
        guard let shared = model.takeShared(in: key) else { return }
        text = shared.text(after: text)
        attachments += shared.attachments
        if let note = shared.note { attachNote = note }
        focused = true
    }

    private var promptBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The start's notes (#4737), shown only while there is one: kept lines would cost
            // the phone's bar lines for ever.
            if let attachNote {
                SheetNote(text: attachNote, reservesSpace: false)
            }
            if let refusal = model.startRefusal {
                SheetNote(text: refusal, reservesSpace: false)
            }
            // In words as well as the spinner, as the Mac's bar says it (#87): a
            // worktree and a runtime to start can take seconds.
            if model.isStarting {
                Telling(host: model.recipient(on: model.startHost), doing: AgentState.startingLabel)
            }
            // What the chips' marks are about, in words, as the Mac's bar says them: the
            // runtime chosen is out (052, 065), Auto picks nothing (#2658), or the
            // organisation sets the sandbox (#998).
            if let out = model.startRuntimeOut {
                // Attention: the person chooses another runtime. The tint is on the icon.
                SheetNote(tone: .attention, text: out, reservesSpace: false)
            }
            if model.startAutoPicksNothing {
                SheetNote(text: LevelWords.noRuntime(model.startAutoPreview?.skipped ?? [], name: PromptWords.runtimeName),
                          reservesSpace: false)
            }
            if let mark = model.sandboxSettings.setBy {
                OrgPolicyLine(mark: mark)
            }
            // The chat's prompt bar (#2621, #2752): one raised card holding the attachments and
            // the words, with attach on the left and dictate and send on the right under them,
            // so starting an agent and talking to one look like the same act.
            VStack(alignment: .leading, spacing: 8) {
                // The choices, above the words (#4556). Off while it starts (#87), and while
                // the host is not answering (#239), when choosing would go nowhere.
                ChoiceChips(labels: draftLabels) { atLabels in
                    moreAtLabels = atLabels
                    showingMore = true
                }
                .disabled(model.isStarting || hostOff)
                if !attachments.isEmpty {
                    AttachmentStrip(attachments: $attachments,
                                    capabilities: model.promptCapabilities(for: model.startRuntimeID),
                                    runtime: model.promptRuntimeName(for: model.startRuntimeID))
                }
                // Voice mode (#2375) in a new session, as on the Mac: its first words start it,
                // and the options stay (Alex, 2026-10-29).
                if voiceIsOn {
                    VoiceSpeechPrompt()
                        .frame(minHeight: 44, alignment: .topLeading)
                        // Left before its first words: a new session's voice mode ends (#2388).
                        .onDisappear { VoiceMode.shared.leave(nil) }
                } else {
                    TextField(policyRefusal ?? "What should it do?", text: $text, selection: $selection, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...8)
                        .focused($focused)
                        .appText(.reading)
                        .overlay(alignment: .topLeading) { HeardUnderline(dictation: dictation, text: text) }
                        .accessibilityLabel("What the new agent should do")
                        // ⌘V of a picture from an iPad's keyboard attaches it (#396).
                        .modifier(PastesPictures(attachments: $attachments, refusal: $attachNote))
                        // Held, words and all, while they start an agent (#87).
                        .disabled(model.isStarting)
                        .frame(minHeight: 44, alignment: .topLeading)
                }

                HStack(spacing: 8) {
                    AttachButton(attachments: $attachments, refusal: $attachNote)

                    Spacer(minLength: 0)
                    DictateButton(dictation: dictation, begin: beginDictation, send: send)
                        .disabled(model.isStarting)

                    VoiceModeButton(agentID: nil, vocabulary: { seeds }, send: sendSpoken)
                        .disabled(model.isStarting)

                    if voiceIsOn {
                        VoiceStopButton()
                    } else {
                        Button {
                            send()
                        } label: {
                            Group {
                                if model.isStarting {
                                    ProgressView()
                                } else {
                                    Image(systemName: "arrow.up")
                                        .appText(.reading).fontWeight(.semibold)
                                }
                            }
                            .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.paperProminent)
                        .buttonBorderShape(.circle)
                        // Bright while its own spinner turns, as the answer that went stays bright
                        // on the cards (#86); `send()` refuses the press meanwhile.
                        .disabled(!canSend && !model.isStarting)
                        .accessibilityLabel("Start agent")
                        .accessibilityValue(model.isStarting ? AgentState.startingLabel : "")
                    }
                }
                // Each button takes a 44 pt tap, though it is drawn at 32 (#2897).
                .environment(\.paperTapTargets, true)
            }
            .padding(10)
            .frame(minHeight: 94, alignment: .topLeading)
            .paperRaised(in: RoundedRectangle(cornerRadius: 18))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Paper.ground)
    }

    /// Why nothing can start on the Mac's host now, in its organisation's words (#998).
    private var policyRefusal: String? {
        model.startHost == .mac ? model.policyState?.composerReason : nil
    }

    /// The folder's host is not answering, and does not start when used (#239, #691 US3).
    private var hostOff: Bool {
        model.isStale(on: model.startHost) && !model.startsWhenUsed(model.startHost)
    }

    private var canSend: Bool {
        guard policyRefusal == nil else { return false }
        // Auto found no runtime that can take it (#2658): the line over the card says why.
        guard !model.startAutoPicksNothing else { return false }
        // Off while the folder's host is not answering, the Mac or its server (#239).
        // A stopped workspace that starts when used keeps the start until it is up (#691 US3).
        return !model.isStarting && (!model.isStale(on: model.startHost) || model.startsWhenUsed(model.startHost))
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func keep() {
        StartDraftKeeper.shared.note(text, attachments, in: folder)
    }

    private func send() {
        // One agent at a time: a second tap while one starts is not a second (#87).
        guard canSend else { return }
        dictation.stop()
        // The keyboard goes, as the chat's does (#2091): what the start says is what comes next.
        focused = false
        let words = text
        let attached = attachments
        Task { _ = await model.startAgent(prompt: words, attachments: attached, labels: draftLabels, in: key, page: page) }
    }

    /// Voice mode is on in this new session, not started yet.
    private var voiceIsOn: Bool { VoiceMode.shared.isOn(in: nil) }

    private var seeds: [String] {
        DictationVocabulary.seeds(folders: model.work.folders, agents: model.work.agents, in: folder)
    }

    /// The first words said in voice mode start the session, with this page's choices, and
    /// say which it is, so voice mode goes on in its chat (#2375).
    private func sendSpoken(_ words: String, _ stopping: UUID?) async -> UUID? {
        var started: UUID?
        guard await model.startAgent(prompt: words, labels: draftLabels, in: key, page: page, voice: true,
                                     started: { started = $0 }) else { return nil }
        return started
    }

    /// Listens, as the chat's bar does: what is in the field stays, and the words go in at
    /// the cursor (#427).
    private func beginDictation() {
        focused = true
        dictation.start(in: text, selection: DictationCursor.range(of: selection, in: text),
                        vocabulary: seeds) { field, cursor in
            text = field
            selection = DictationCursor.selection(cursor, in: field)
        }
    }
}
