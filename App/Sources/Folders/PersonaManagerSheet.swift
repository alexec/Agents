import AgentsKitCore
import SwiftUI

/// Edit the original Markdown so unknown front matter remains unchanged.
struct PersonaManagerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: MachineRef
    let folder: URL
    var personalOnly = false

    @State private var origin: Persona.Origin = .folder
    @State private var files: [DaemonAPI.PersonaFile] = []
    @State private var selected: String?
    @State private var id = ""
    @State private var content = ""
    @State private var problem: String?
    @State private var deleting = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Personas").appText(.title)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.paper)
            }
            if personalOnly {
                Text("Personal personas").appText(.fine).foregroundStyle(.secondary)
            } else {
                Picker("Scope", selection: $origin) {
                    Text("This folder").tag(Persona.Origin.folder)
                    Text("Personal").tag(Persona.Origin.personal)
                }
                .pickerStyle(.segmented)
                .onChange(of: origin) { clear(); Task { await load() } }
            }
            HStack(spacing: 6) {
                ForEach(files) { file in
                    Button(file.id) { select(file) }
                        .buttonStyle(.paper)
                        .fontWeight(selected == file.id ? .semibold : .regular)
                }
                Button("New persona") { clear() }.buttonStyle(.paper)
            }
            TextField("File name", text: $id)
                .textFieldStyle(.roundedBorder)
                .disabled(selected != nil)
            TextEditor(text: $content)
                .appText(.code)
                .frame(minHeight: 280)
                .padding(6)
                .background(Paper.raised, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Paper.rule, lineWidth: 1))
            Text("Edit the full Markdown file to keep front matter fields the app does not know.")
                .appText(.fine).foregroundStyle(.secondary)
            if let problem { Text(problem).appText(.fine).tinted(.failure) }
            HStack {
                if selected != nil { Button("Delete…", role: .destructive) { deleting = true }.buttonStyle(.paper) }
                Spacer()
                Button(busy ? "Saving…" : "Save") { Task { await save() } }
                    .buttonStyle(.paperProminent).disabled(busy || id.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 560)
        .task {
            if personalOnly { origin = .personal }
            await load()
        }
        .confirmationDialog("Delete this persona?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await save(remove: true) } }
        }
    }

    private func clear() {
        selected = nil; id = ""; content = ""; problem = nil
    }

    private func select(_ file: DaemonAPI.PersonaFile) {
        selected = file.id; id = file.id; content = file.content; problem = nil
    }

    private func load() async {
        guard let listed = await model.personaFiles(on: host, folder: folder, origin: origin) else {
            problem = "Personas could not be loaded."; return
        }
        files = listed
    }

    private func save(remove: Bool = false) async {
        busy = true
        let ok = await model.savePersonaFile(on: host, folder: folder, origin: origin, id: id, content: content, delete: remove)
        busy = false
        guard ok else { problem = "The persona could not be saved."; return }
        if remove { clear() } else { selected = id }
        await load()
    }
}
