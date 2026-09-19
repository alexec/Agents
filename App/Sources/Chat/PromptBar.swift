import AgentsKit
import SwiftUI

/// The prompt, and the controls around it.
///
/// The same thing before an agent exists and after. Starting an agent does not swap one
/// control for another: the bar moves down the pane and the conversation appears above
/// it, which is why this is one view rather than a start form and a composer.
struct PromptBar: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var showFolderPicker = false
    @FocusState private var focused: Bool

    private var agent: Agent? { model.selectedAgent }
    private var isNew: Bool { agent == nil }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                whereAndWhat
                field
                options
            }
        }
        .padding(20)
        .onChange(of: model.selection) { text = "" }
        .onAppear { prepare() }
        .onChange(of: model.availableRuntimes.map(\.id)) { prepare() }
        .onChange(of: model.agents.count) { prepare() }
    }

    // MARK: The folder, and what runs in it

    private var whereAndWhat: some View {
        HStack(spacing: 12) {
            if let agent {
                Text(agent.cwd.path(percentEncoded: false))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 8)
                Text(runtimeName(agent.runtimeID))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Button(action: chooseFolder) {
                    Text(model.draftCwd.map { $0.path(percentEncoded: false) } ?? "Choose a folder")
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .buttonStyle(.glass)
                .font(.footnote)

                Spacer(minLength: 8)

                Menu(model.draftRuntimeID.map(runtimeName) ?? "Runtime") {
                    ForEach(model.availableRuntimes) { status in
                        Button(status.runtime.name) { chooseRuntime(status.runtime.id) }
                    }
                }
                .menuStyle(.borderlessButton)
                .font(.footnote)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassEffect(.regular.interactive(), in: .capsule)
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

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.headline)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
    }

    private var placeholder: String {
        guard let agent else { return "Say what you want done" }
        switch agent.state {
        case .running: return "Working…"
        case .waitingOnUser: return "Answer the question above, or stop it"
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
            HStack(spacing: 10) {
                WrappingRow(spacing: 10, lineSpacing: 10) {
                    ForEach(shown.filter(\.isAboutPermission)) { option in
                        OptionMenu(option: option, chosen: binding(for: option))
                    }
                }
                Spacer(minLength: 16)
                WrappingRow(spacing: 10, lineSpacing: 10) {
                    ForEach(shown.filter { !$0.isAboutPermission }) { option in
                        OptionMenu(option: option, chosen: binding(for: option))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private var canSend: Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if let agent { return agent.state != .running }
        return model.draftCwd != nil && model.draftRuntimeID != nil
    }

    private func send() {
        guard canSend else { return }
        let outgoing = text
        text = ""
        Task {
            if agent == nil {
                await model.startDraft(prompt: outgoing)
            } else {
                await model.send(outgoing)
            }
        }
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
