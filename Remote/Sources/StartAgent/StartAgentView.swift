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
    let project: URL

    @State private var text = ""
    @State private var attachments: [Attachment] = []
    @State private var draftLabels: [String] = []
    @State private var folderPath = ""
    /// Why something picked could not be attached, or that a kept picture was too big
    /// to keep and needs picking again.
    @State private var attachNote: String?
    @FocusState private var focused: Bool

    var body: some View {
        form
        .onAppear {
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
        .onDisappear { StartDraftKeeper.shared.flush() }
        // A start on a server with no key of its own asks for one here, over the page (#344).
        .tokenAskSheet(model)
    }

    private var form: some View {
        Form {
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
            personaSection
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
        .navigationTitle(model.work.project(project)?.name ?? "New session")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { HostOfflineStrip(host: model.startHost) }
        .safeAreaInset(edge: .bottom, spacing: 0) { promptBar }
    }

    /// The project's personas, first (#760): segments on a project, a menu on the chat
    /// project, and what the picked one is for under them. Not drawn where there are none.
    @ViewBuilder private var personaSection: some View {
        let usable = model.startPersonas.filter { $0.problem == nil }
        let broken = model.startPersonas.filter { $0.problem != nil }
        if !model.startPersonas.isEmpty {
            Section {
                let selection = Binding<String>(get: { model.startPersona ?? "" },
                                                set: { id in pickPersona(id) })
                if !usable.isEmpty {
                    if model.work.project(project)?.isChat == true {
                        Picker("Persona", selection: selection) {
                            Text("None").tag("")
                            ForEach(usable) { Text($0.name).tag($0.id) }
                        }
                    } else {
                        Picker("Persona", selection: selection) {
                            Text("None").tag("")
                            ForEach(usable) { Text($0.name).tag($0.id) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                ForEach(broken) { persona in
                    Text("\(persona.id).md: \(persona.problem ?? "")")
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if let description = usable.first(where: { $0.id == model.startPersona })?.description {
                    Text(description)
                }
            }
            .disabled(model.isStarting)
        }
    }

    /// Every setting the persona names, and its labels beside any already there.
    private func pickPersona(_ id: String) {
        let persona = model.startPersonas.first { $0.id == id }
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
                TextField("What should it do?", text: $text, axis: .vertical)
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

    private var canSend: Bool {
        // Off while the project's host is not answering, the Mac or its server (#239).
        // A stopped workspace that starts when used keeps the start until it is up (#691 US3).
        !model.isStarting && (!model.isStale(on: model.startHost) || model.startsWhenUsed(model.startHost))
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func keep() {
        StartDraftKeeper.shared.note(text, attachments, in: project)
    }

    private func send() {
        // One agent at a time: a second tap while one starts is not a second (#87).
        guard canSend else { return }
        let words = text
        let attached = attachments
        Task { _ = await model.startAgent(prompt: words, attachments: attached, labels: draftLabels) }
    }
}
