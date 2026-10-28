import AgentsKitCore
import SwiftUI

/// Edit persona Markdown from the new session form. Keeping the whole file in the editor
/// preserves front matter fields this version does not understand.
struct PersonaManagerView: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let folder: URL

    @State private var origin: Persona.Origin = .folder
    @State private var files: [DaemonAPI.PersonaFile] = []
    @State private var selected: String?
    @State private var id = ""
    @State private var content = ""
    @State private var problem: String?
    @State private var deleting = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Scope", selection: $origin) {
                        Text("This folder").tag(Persona.Origin.folder)
                        Text("Personal").tag(Persona.Origin.personal)
                    }
                    .onChange(of: origin) { clear(); Task { await load() } }
                    ForEach(files) { file in
                        Button(file.id) { select(file) }
                            .fontWeight(selected == file.id ? .semibold : .regular)
                    }
                    Button("New persona") { clear() }
                } header: { Text("Persona files") }

                Section {
                    TextField("File name", text: $id)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(selected != nil)
                    TextEditor(text: $content)
                        .appText(.code)
                        .frame(minHeight: 260)
                        .accessibilityLabel("Persona Markdown")
                    if let problem { Text(problem).appText(.fine).tinted(.failure) }
                } header: { Text("Markdown") } footer: {
                    Text("The full file stays intact, including front matter fields this app does not know.")
                }
            }
            .navigationTitle("Personas")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    if selected != nil { Button("Delete", role: .destructive) { deleting = true } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Saving…" : "Save") { Task { await save() } }.disabled(busy || id.isEmpty)
                }
            }
            .confirmationDialog("Delete this persona?", isPresented: $deleting, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await save(remove: true) } }
                Button("Cancel", role: .cancel) {}
            }
            .task { await load() }
        }
    }

    private func clear() {
        selected = nil
        id = ""
        content = ""
        problem = nil
    }

    private func select(_ file: DaemonAPI.PersonaFile) {
        selected = file.id
        id = file.id
        content = file.content
        problem = nil
    }

    private func load() async {
        guard let listed = await model.personaFiles(in: folder, origin: origin) else {
            problem = "Personas could not be loaded."
            return
        }
        files = listed
    }

    private func save(remove: Bool = false) async {
        busy = true
        let failure = await model.savePersonaFile(in: folder, origin: origin, id: id, content: content, delete: remove)
        busy = false
        if let failure { problem = failure; return }
        if remove { clear() } else { selected = id }
        await load()
    }
}
