import AgentsKitCore
import SwiftUI

/// New session, on a phone: a runtime, what it offers, and what to ask it (029).
///
/// The choices sit above and the prompt sits at the bottom, over the keyboard, so that
/// with the keyboard up the words and Send are what is in view, and the choices are a
/// scroll away rather than behind it.
///
/// The project's own page (#366): what its row opens, in the detail rather than a sheet
/// over it, as the Mac's project row opens its new-session chat. Leaving keeps what was
/// typed. It goes only when the agent it was typed for exists, which is the model's to
/// say, not this view's: by then the page has gone.
struct StartAgentView: View {
    @Environment(RemoteModel.self) private var model
    /// The project of the scene this is in, when that is a project's own (#1089).
    @Environment(\.sceneProject) private var sceneProject
    let project: URL

    @State private var text = ""
    @State private var attachments: [Attachment] = []
    @State private var draftLabels: [String] = []
    @State private var folderPath = ""
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
            model.composingScene = sceneProject
            model.startPageAppeared(in: project, page: page)
            let kept = StartDraftKeeper.shared.draft(in: project)
            text = kept?.text ?? ""
            attachments = kept?.attachments ?? []
            if kept?.droppedInlineData == true {
                // Said rather than restored silently incomplete (025's rule).
                attachNote = "What was attached was too big to keep with the draft. Attach it again."
            }
            // After the kept draft, so a view's prompt is what the field holds (#834).
            takeOffer()
            focused = true
        }
        .onChange(of: model.offeredStart) { takeOffer() }
        // Which showing holds the page is the model's (#2089): the last to come, and the
        // one under it once that goes. But an iPhone says this showing went just after it
        // came, and it stays on screen with nothing behind it: a showing still told of
        // changes takes the page back when nothing holds it. Not one that holds nothing
        // because it is going: the model knows which started their agent. A count, not
        // `startingIn`: that went to the project and back to nil before a frame was drawn.
        .onChange(of: model.startPageLetGo) {
            model.startPageStillShown(in: project, page: page)
        }
        // Said once, when it arrives: a refusal is the one thing on this page a person
        // using VoiceOver would otherwise have to go looking for.
        .onChange(of: model.startRefusal) {
            if let refusal = model.startRefusal { AccessibilityNotification.Announcement(refusal).post() }
        }
        .onChange(of: attachNote) {
            if let attachNote { AccessibilityNotification.Announcement(attachNote).post() }
        }
        .onChange(of: text) { keep() }
        .onChange(of: attachments) { keep() }
        .onDisappear {
            StartDraftKeeper.shared.flush()
            model.startPageDisappeared(page)
        }
        // A start on a server with no key of its own asks for one here, over the page (#344).
        .tokenAskSheet(model)
    }

    private var form: some View {
        Form {
            // The Blobs (#987): at the pointer on an iPad with one, else down at the prompt.
            Section {
                Huddle(promptFocused: focused, pointer: pointer, typed: text.count)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
            personaHeading
            // Starts kept for this project's stopped workspace (#691 US3, layouts.md L6a): the
            // agent each makes opens once the host is up.
            if case let starts = model.keptStarts(in: project), !starts.isEmpty {
                Section {
                    ForEach(starts) { KeptPromptRow(kept: $0) }
                        .listRowBackground(Color.clear)
                }
                .environment(\.chatActions, ChatActions(
                    dropKept: { [model] in await model.dropKept($0) },
                    retryKept: { [model] in await model.retryKept($0) },
                    hostName: { [model] in model.hostName($0) }))
            }
            // A change to the project's own files that no session can be asked about (#531).
            if let key = model.work.project(project)?.key {
                ForEach(model.work.guardedChanges(ofProject: key)) { change in
                    Section {
                        GuardedChangeQuestion(change: change, key: key)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
            }
            ChoiceRows()
            Section("Reach") {
                ForEach(model.startFolders, id: \.self) { folder in
                    HStack {
                        Text(folder.path).lineLimit(1)
                        Spacer()
                        Button("Remove") { model.startFolders.removeAll { $0 == folder } }
                    }
                }
                HStack {
                    TextField("Folder path", text: $folderPath)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Add") {
                        let folder = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath)
                        if !model.startFolders.contains(folder) { model.startFolders.append(folder) }
                        folderPath = ""
                    }
                    .disabled(folderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            Section("Labels") {
                LabelTagField(labels: draftLabels.map { SessionLabel(value: $0, owner: .person) },
                              suggestions: model.labelSuggestions(in: project),
                              add: { draftLabels += $0 },
                              remove: { value in
                                  draftLabels.removeAll { SessionLabelPolicy.key($0) == SessionLabelPolicy.key(value) }
                              })
            }
        }
        .paperForm()
        .onContinuousHover(coordinateSpace: .global) { phase in
            if case let .active(location) = phase { pointer = location } else { pointer = nil }
        }
        .navigationTitle(model.work.project(project)?.name ?? "New session")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HostOfflineStrip(host: model.startHost)
                HostDiskStrip(host: model.startHost)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { promptBar }
    }

    /// The kind of session to start (#760), at the top of the page as a heading-style menu
    /// (#913), with what the picked one is for, and any persona file that cannot be read,
    /// under it. The project stays the title. Not drawn where there are none.
    @ViewBuilder private var personaHeading: some View {
        let usable = model.startPersonas.filter { $0.problem == nil }
        let broken = model.startPersonas.filter { $0.problem != nil }
        let picked = usable.first { $0.id == model.startPersona }
        if !model.startPersonas.isEmpty {
            Section {
                VStack(spacing: 4) {
                    if !usable.isEmpty {
                        Menu {
                            personaButton(nil, picked: picked == nil)
                            ForEach(usable) { personaButton($0, picked: $0.id == picked?.id) }
                        } label: {
                            HStack(spacing: 5) {
                                Text(picked?.name ?? Self.noPersona)
                                    .appText(.reading).fontWeight(.semibold)
                                    .foregroundStyle(picked == nil ? .secondary : .primary)
                                    .lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down")
                                    .imageScale(.small)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Persona: \(picked?.name ?? Self.noPersona)")
                    }
                    if let description = picked?.description {
                        Text(description)
                            .appText(.supporting)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(broken) { persona in
                        Text("\(persona.id).md: \(persona.problem ?? "")")
                            .appText(.supporting)
                            .foregroundStyle(.secondary)
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

    private func personaButton(_ persona: Persona?, picked: Bool) -> some View {
        Button {
            pickPersona(persona)
        } label: {
            if picked {
                Label(persona?.name ?? Self.noPersona, systemImage: "checkmark")
            } else {
                Text(persona?.name ?? Self.noPersona)
            }
        }
    }

    /// Every setting the persona names, and its labels beside any already there.
    private func pickPersona(_ persona: Persona?) {
        for label in persona?.settings.labels ?? []
        where !draftLabels.contains(where: { SessionLabelPolicy.key($0) == SessionLabelPolicy.key(label) }) {
            draftLabels.append(label)
        }
        Task { await model.choosePersona(persona) }
    }

    /// What a view filled the page with (#834): its prompt in the field, unsent, and its
    /// labels beside any already there. Its worktree is the model's to choose.
    private func takeOffer() {
        guard let start = model.takeOfferedStart(in: project) else { return }
        text = start.prompt
        // Held to what a session takes, as a label typed here is.
        draftLabels += SessionLabelPolicy.accepted(start.labels, existing: draftLabels)
        focused = true
    }

    private var promptBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                AttachmentStrip(attachments: $attachments,
                                capabilities: model.promptCapabilities(for: model.startRuntimeID))
            }
            if let attachNote {
                Text(attachNote).appText(.supporting).tinted(.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let refusal = model.startRefusal {
                Text(refusal)
                    .appText(.supporting)
                    .tinted(.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // In words as well as the spinner, as the Mac's bar says it (#87): a
            // worktree and a runtime to start can take seconds.
            if model.isStarting {
                Telling(host: model.recipient(on: model.startHost), doing: AgentState.startingLabel)
            }
            // The chat's prompt bar: one raised card holding the words, attach, and send
            // in ink, so starting an agent and talking to one look like the same act.
            HStack(alignment: .bottom, spacing: 8) {
                TextField(policyRefusal ?? "What should it do?", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...6)
                    .focused($focused)
                    .appText(.reading)
                    .accessibilityLabel("What the new agent should do")
                    // ⌘V of a picture from an iPad's keyboard attaches it (#396).
                    .modifier(PastesPictures(attachments: $attachments, refusal: $attachNote))
                    // Held, words and all, while they start an agent (#87).
                    .disabled(model.isStarting)

                AttachButton(attachments: $attachments, refusal: $attachNote)

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
            .padding(14)
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

    private var canSend: Bool {
        guard policyRefusal == nil else { return false }
        // Off while the project's host is not answering, the Mac or its server (#239).
        // A stopped workspace that starts when used keeps the start until it is up (#691 US3).
        return !model.isStarting && (!model.isStale(on: model.startHost) || model.startsWhenUsed(model.startHost))
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func keep() {
        StartDraftKeeper.shared.note(text, attachments, in: project)
    }

    private func send() {
        // One agent at a time: a second tap while one starts is not a second (#87).
        guard canSend else { return }
        // The keyboard goes, as the chat's does (#2091): what the start says is what comes next.
        focused = false
        let words = text
        let attached = attachments
        Task { _ = await model.startAgent(prompt: words, attachments: attached, labels: draftLabels, in: project, page: page) }
    }
}
