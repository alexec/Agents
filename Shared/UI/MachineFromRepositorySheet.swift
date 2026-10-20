import AgentsKitCore
import SwiftUI

/// Start a Machine from a Repository (#1809), drawn by the window and the Remote as the web
/// page's MachineDialog: the repository, a provider that makes machines, its New Workspace
/// form, and Start. What comes next is said in the sheet: joining on its first boot, or made
/// but to add as a host in the Mac app. Each app gives it its way to the control plane.
struct MachineFromRepositorySheet: View {
    typealias Words = MachineFromRepository.Words

    /// The control plane's calls, as each app makes them. A refusal is thrown, and said.
    struct Calls {
        var providers: @MainActor () async throws -> [DaemonAPI.ProviderSummary]
        var options: @MainActor (ProviderID) async throws -> JSONValue
        var create: @MainActor (DaemonAPI.ProviderCreate) async throws -> DaemonAPI.ProviderCreated
    }

    let calls: Calls
    let close: @MainActor () -> Void
    /// How a refusal reads, in each app's words.
    let sentence: (any Error) -> String

    @State private var text = ""
    @State private var makers: [DaemonAPI.ProviderSummary]?
    @State private var provider: ProviderID?
    @State private var fields: [MachineFromRepository.Field] = []
    @State private var suffix = MachineFromRepository.nameSuffix()
    @State private var starting = false
    @State private var said: String?
    @State private var failed = false

    private var repository: MachineFromRepository.Repository? { MachineFromRepository.repository(text) }
    private var name: String { repository.map { MachineFromRepository.machineName($0.name, suffix: suffix) } ?? "" }
    private var done: Bool { said != nil && !failed }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Words.title).appText(.reading).fontWeight(.semibold)
            if let makers, makers.isEmpty {
                Text(Words.noMakers).appText(.fine).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                TextField(Words.repositoryPrompt, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .disabled(starting || done)
                    .accessibilityLabel("Repository")
                let typed = !text.trimmingCharacters(in: .whitespaces).isEmpty
                note(Words.repositoryNote(repository, typed: typed), failing: typed && repository == nil)
                Picker("Provider", selection: $provider) {
                    ForEach(makers ?? []) { Text($0.name).tag(Optional($0.id)) }
                }
                .disabled(starting || done)
                ForEach($fields) { $field in
                    if let choices = field.choices {
                        Picker(field.title, selection: $field.value) {
                            ForEach(choices, id: \.self) { Text($0).tag($0) }
                        }
                        .disabled(starting || done)
                    } else {
                        LabeledContent(field.title) {
                            TextField(field.title, text: $field.value).textFieldStyle(.roundedBorder).disabled(starting || done)
                        }
                    }
                }
                if !name.isEmpty {
                    Text("Its name: \(name). \(Words.privateNote)").appText(.fine).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if starting { Text(Words.starting(name)).appText(.fine).foregroundStyle(.secondary) }
            if let said { note(said, failing: failed) }
            HStack {
                Spacer()
                if done {
                    Button("Done") { close() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { close() }.keyboardShortcut(.cancelAction)
                    Button("Start") { Task { await start() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(repository == nil || provider == nil || starting)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 320, idealWidth: 460)
        .task { await load() }
        .onChange(of: provider) { _, chosen in Task { await loadForm(chosen) } }
    }

    @ViewBuilder
    private func note(_ words: String, failing: Bool) -> some View {
        if failing {
            Text(words).appText(.fine).tinted(.failure).fixedSize(horizontal: false, vertical: true)
        } else {
            Text(words).appText(.fine).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func load() async {
        let all = (try? await calls.providers()) ?? []
        makers = MachineFromRepository.makers(all)
        provider = makers?.first?.id
    }

    private func loadForm(_ chosen: ProviderID?) async {
        guard let chosen else { return fields = [] }
        fields = MachineFromRepository.fields(try? await calls.options(chosen))
    }

    private func start() async {
        guard let repository, let provider else { return }
        starting = true
        defer { starting = false }
        do {
            let made = try await calls.create(MachineFromRepository.request(provider, name: name, repository: repository,
                                                                            fields: fields))
            let by = makers?.first { $0.id == provider }?.name ?? "The provider"
            failed = false
            said = made.joining ? Words.joining(made.workspace.name, repository)
                : Words.notJoining(made.workspace.name, provider: by)
        } catch {
            failed = true
            said = sentence(error)
        }
    }
}

extension MachineFromRepositorySheet.Calls {
    /// The calls over a client of the control plane, as both apps hold one.
    static func through(_ control: DaemonClient) -> Self {
        Self(providers: {
            let answer = try await control.call(DaemonAPI.Method.providersList, DaemonAPI.Empty(), returning: JSONValue.self)
            return try answer["providers"]?.decode([DaemonAPI.ProviderSummary].self) ?? []
        }, options: { id in
            try await control.call(DaemonAPI.Method.providersOptions, DaemonAPI.ProviderRequest(id: id),
                                   returning: DaemonAPI.ProviderOptions.self).schema
        }, create: { request in
            try await control.call(DaemonAPI.Method.providersCreate, request, returning: DaemonAPI.ProviderCreated.self)
        })
    }
}
