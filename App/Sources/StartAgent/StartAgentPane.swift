import AgentsKit
import SwiftUI

/// Starting an agent, in the pane where the agent will appear.
///
/// Three rows and nothing else: where it works and what runs it, what you want done, and
/// the options that runtime offers. It is what the right-hand side shows when no agent is
/// chosen, so the app opens ready to start one rather than ready to be told to.
struct StartAgentPane: View {
    @Environment(AppModel.self) private var model

    @State private var cwd: URL?
    @State private var runtimeID: String?
    @State private var instruction = ""
    @State private var options: [ConfigOption] = []
    @State private var chosen: [String: JSONValue] = [:]
    @State private var draftID: UUID?
    @State private var isLoadingOptions = false
    @State private var isStarting = false
    @FocusState private var promptFocused: Bool

    var body: some View {
        // One container for the whole form: the folder, the runtime, the prompt and
        // the options are one set of controls, so they blend as one rather than as
        // five separate pieces of glass.
        GlassEffectContainer(spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                whereAndWhat
                prompt
                optionsRow
                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("New agent")
        .onChange(of: runtimeID) { loadOptions() }
        .onChange(of: cwd) { loadOptions() }
        .onAppear {
            chooseFirstRuntime()
            chooseLastFolder()
        }
        // The runtimes arrive from the daemon a moment after the window does, so the
        // first one is taken when it turns up rather than only when this appears.
        .onChange(of: model.availableRuntimes.map(\.id)) { chooseFirstRuntime() }
        .onChange(of: model.agents.count) { chooseLastFolder() }
    }

    // MARK: Row 1 — where it works, and what runs it

    private var whereAndWhat: some View {
        HStack(spacing: 12) {
            Button(action: chooseFolder) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text(cwd.map { $0.path(percentEncoded: false) } ?? "Choose a folder")
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .buttonStyle(.glass)
            .help("The folder the agent works in")

            Spacer(minLength: 8)

            // The runtimes name themselves, so the menu says which one without being
            // told it is a runtime.
            Menu(runtimeName ?? "Runtime") {
                ForEach(model.availableRuntimes) { status in
                    Button(status.runtime.name) { runtimeID = status.runtime.id }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular.interactive(), in: .capsule)
            .disabled(model.availableRuntimes.isEmpty)
        }
    }

    // MARK: Row 2 — what you want done

    private var prompt: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Say what you want done", text: $instruction, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.title3)
                .lineLimit(2...12)
                .focused($promptFocused)

            Button(action: start) {
                Image(systemName: "arrow.up")
                    .font(.headline)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(!canStart)
            .keyboardShortcut(.return, modifiers: .command)
            .help(canStart ? "Start the agent" : "Choose a folder and say what you want done")
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: Row 3 — whatever this runtime offers

    @ViewBuilder
    private var optionsRow: some View {
        if isLoadingOptions {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Asking \(runtimeName ?? "the runtime") what it offers…")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        } else if !options.isEmpty {
            // Worked out across the row, not one control at a time: two menus both
            // reading "Default" say nothing.
            let titles = options.closedTitles(chosen: chosen)
            WrappingRow(spacing: 10, lineSpacing: 10) {
                ForEach(options) { option in
                    OptionMenu(option: option, title: titles[option.id] ?? option.name, chosen: $chosen)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Doing it

    private var runtimeName: String? {
        runtimeID.flatMap { RuntimeCatalog.runtime(id: $0)?.name }
    }

    private var canStart: Bool {
        cwd != nil && runtimeID != nil && !isStarting
            && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Open on the folder the last agent was started in.
    ///
    /// Agents get started in the same handful of folders, so an empty chooser is a
    /// click asking for something the app already knows. Choosing another is one click
    /// from here either way.
    private func chooseLastFolder() {
        guard cwd == nil else { return }
        cwd = model.agents.first?.cwd
    }

    private func chooseFirstRuntime() {
        guard runtimeID == nil || !model.availableRuntimes.contains(where: { $0.id == runtimeID }) else { return }
        runtimeID = model.availableRuntimes.first?.id
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Work here"
        if panel.runModal() == .OK { cwd = panel.url }
    }

    /// The options only exist once a session does, so choosing a folder and a runtime
    /// starts one. It is kept as a draft and used by the start that follows, so the
    /// runtime is started once.
    private func loadOptions() {
        guard let runtimeID, let cwd else { return }
        isLoadingOptions = true
        options = []
        chosen = [:]
        draftID = nil
        Task {
            let response = await model.options(runtimeID: runtimeID, cwd: cwd)
            await MainActor.run {
                isLoadingOptions = false
                guard let response else { return }
                draftID = response.draftID
                options = response.options.filter(\.isRenderable).sorted { $0.categoryRank < $1.categoryRank }
                for option in options where option.currentValue != nil {
                    chosen[option.id] = option.currentValue
                }
                promptFocused = true
            }
        }
    }

    private func start() {
        guard canStart, let runtimeID, let cwd else { return }
        isStarting = true
        let request = DaemonAPI.StartRequest(runtimeID: runtimeID,
                                             cwd: cwd,
                                             prompt: instruction,
                                             startOptions: StartOptions(values: chosen),
                                             draftID: draftID)
        Task {
            await model.start(request)
            await MainActor.run {
                isStarting = false
                instruction = ""
                draftID = nil
            }
        }
    }
}
