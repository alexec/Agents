import AgentsKit
import SwiftUI

/// Pick a folder, pick a runtime, say what you want done.
struct StartAgentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var cwd: URL?
    @State private var runtimeID: String?
    @State private var instruction = ""
    @State private var options: [ConfigOption] = []
    @State private var chosen: [String: JSONValue] = [:]
    @State private var extraArguments = ""
    @State private var draftID: UUID?
    @State private var isLoadingOptions = false
    @State private var isStarting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    LabeledContent("Folder") {
                        HStack {
                            Text(cwd?.path(percentEncoded: false) ?? "Choose a folder")
                                .foregroundStyle(cwd == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer()
                            Button("Choose…", action: chooseFolder)
                        }
                    }
                    Picker("Runtime", selection: $runtimeID) {
                        Text("Choose").tag(String?.none)
                        ForEach(model.availableRuntimes) { status in
                            Text(status.runtime.name).tag(String?.some(status.runtime.id))
                        }
                    }
                }

                if isLoadingOptions {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Asking \(runtimeName) what it offers…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !options.isEmpty {
                    OptionsForm(options: options, chosen: $chosen)
                }

                Section("Extra arguments") {
                    TextField("Anything the runtime takes that it does not advertise", text: $extraArguments)
                        .font(.system(.body, design: .monospaced))
                }

                Section("What do you want done") {
                    TextField("Say what you want done", text: $instruction, axis: .vertical)
                        .lineLimit(3...10)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isStarting ? "Starting…" : "Start") { start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
            .padding(12)
        }
        .frame(width: 560, height: 560)
        .onChange(of: runtimeID) { loadOptions() }
        .onChange(of: cwd) { loadOptions() }
    }

    private var runtimeName: String {
        runtimeID.flatMap { RuntimeCatalog.runtime(id: $0)?.name } ?? "the runtime"
    }

    private var canStart: Bool {
        cwd != nil && runtimeID != nil && !isStarting
            && !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    /// starts one. It is kept and used by Start, so the runtime is started once.
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
            }
        }
    }

    private func start() {
        guard let runtimeID, let cwd else { return }
        isStarting = true
        let request = DaemonAPI.StartRequest(
            runtimeID: runtimeID,
            cwd: cwd,
            prompt: instruction,
            startOptions: StartOptions(values: chosen, extraArguments: splitArguments(extraArguments)),
            draftID: draftID)
        Task {
            await model.start(request)
            await MainActor.run { dismiss() }
        }
    }

    /// Split the way a shell would, so quoted arguments survive.
    private func splitArguments(_ text: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty { arguments.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { arguments.append(current) }
        return arguments
    }
}
