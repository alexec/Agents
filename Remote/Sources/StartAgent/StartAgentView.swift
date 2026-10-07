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
            focused = true
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
        .onDisappear { StartDraftKeeper.shared.flush() }
        // A start on a server with no key of its own asks for one here, over the page (#344).
        .tokenAskSheet(model)
    }

    private var form: some View {
        Form {
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
        !model.isStarting && !model.isStale(on: model.startHost)
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
