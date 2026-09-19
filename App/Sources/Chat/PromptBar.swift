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
        .padding(.horizontal, 72)
        .padding(.vertical, 20)
        .onChange(of: model.selection) { text = "" }
        .onAppear { prepare() }
        .onChange(of: model.availableRuntimes.map(\.id)) { prepare() }
        .onChange(of: model.agents.count) { prepare() }
    }

    // MARK: The folder, and what runs in it

    private var whereAndWhat: some View {
        HStack(spacing: 12) {
            if let agent {
                Text(agent.cwd.lastPathComponent)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(agent.cwd.path(percentEncoded: false))
                Spacer(minLength: 8)
                Text(runtimeName(agent.runtimeID))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Button(action: chooseFolder) {
                    // The folder's own name. The path it sits under is rarely the
                    // thing you are checking, and it is in the tooltip when it is.
                    Text(model.draftCwd?.lastPathComponent ?? "Choose a folder")
                        .lineLimit(1)
                }
                .buttonStyle(.glass)
                .font(.footnote)
                .help(model.draftCwd.map { "Folder: \($0.path(percentEncoded: false))" } ?? "Folder")

                Spacer(minLength: 8)

                SelectCapsule(name: "Runtime",
                              title: model.draftRuntimeID.map(runtimeName) ?? "Runtime") { dismiss in
                    ForEach(model.availableRuntimes) { status in
                        SelectChoice(title: status.runtime.name,
                                     description: nil,
                                     isChosen: status.runtime.id == model.draftRuntimeID) {
                            chooseRuntime(status.runtime.id)
                            dismiss()
                        }
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
                    send()
                    return .handled
                }

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
            //
            // One arrangement, deliberately. Anything that measures the width and
            // picks a layout from it can end up re-measuring what it just changed,
            // and AppKit kills the app when that loop reaches the window: first a
            // custom Layout did it, then ViewThatFits did it intermittently. These
            // are a few short capsules and they fit.
            HStack(spacing: 10) {
                permissionOptions(shown)
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
