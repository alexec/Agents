import AgentsKitCore
import SwiftUI

/// New agent, on a phone: a runtime, what it offers, and what to ask it (029).
///
/// The choices sit above and the prompt sits at the bottom, over the keyboard, so that
/// with the keyboard up the words and Send are what is in view, and the choices are a
/// scroll away rather than behind it.
///
/// Cancel keeps what was typed. It goes only when the agent it was typed for exists,
/// which is the model's to say, not this view's: by then the sheet has gone.
struct StartAgentView: View {
    @Environment(RemoteModel.self) private var model
    let project: URL

    @State private var text = ""
    @State private var attachments: [Attachment] = []
    /// Why something picked could not be attached, or that a kept picture was too big
    /// to keep and needs picking again.
    @State private var attachNote: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                ChoiceRows()
            }
            .navigationTitle(model.work.project(project)?.name ?? "New agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.startingIn = nil }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { promptBar }
        }
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
        // Said once, when it arrives: a refusal is the one thing on this sheet a person
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
            HStack(alignment: .bottom, spacing: 8) {
                AttachButton(attachments: $attachments, refusal: $attachNote)
                TextField("What should it do?", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...6)
                    .focused($focused)
                    .appText(.reading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityLabel("What the new agent should do")

                Button {
                    send()
                } label: {
                    Group {
                        if model.isStarting {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.up")
                                // Decorative: a glyph in a button, not text.
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.4)
                .accessibilityLabel("Start agent")
                .accessibilityValue(model.isStarting ? AgentState.startingLabel : "")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var canSend: Bool {
        !model.isStarting && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func keep() {
        StartDraftKeeper.shared.note(text, attachments, in: project)
    }

    private func send() {
        let words = text
        let attached = attachments
        Task { _ = await model.startAgent(prompt: words, attachments: attached) }
    }
}
