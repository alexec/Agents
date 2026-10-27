import AgentsKitCore
import SwiftUI

/// A file's two editable parts. The YAML is kept as text so unknown keys survive.
struct AgentConfigMarkdown {
    var frontmatter: String
    var markdown: String
    var hasFrontmatter: Bool

    init(frontmatter: String, markdown: String, hasFrontmatter: Bool) {
        self.frontmatter = frontmatter
        self.markdown = markdown
        self.hasFrontmatter = hasFrontmatter
    }

    init(_ content: String) {
        guard content.hasPrefix("---\n"),
              let close = content.range(of: "\n---\n", range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex) else {
            frontmatter = ""
            markdown = content
            hasFrontmatter = false
            return
        }
        frontmatter = String(content[content.index(content.startIndex, offsetBy: 4)..<close.lowerBound])
        markdown = String(content[close.upperBound...])
        hasFrontmatter = true
    }

    var content: String {
        hasFrontmatter || !frontmatter.isEmpty ? "---\n\(frontmatter)\n---\n\(markdown)" : markdown
    }
}

/// Skills, personas and workflows use the same file selector and editor on Mac and Remote.
struct AgentConfigFileEditor: View {
    let kind: DaemonAPI.AgentConfigEditorKind
    let location: String
    let load: @MainActor () async -> [DaemonAPI.AgentConfigEditorFile]?
    let saveFile: @MainActor (_ path: String, _ content: String, _ delete: Bool) async -> String?

    @State private var files: [DaemonAPI.AgentConfigEditorFile] = []
    @State private var selected: String?
    @State private var newName = ""
    @State private var frontmatter = ""
    @State private var markdown = ""
    @State private var original = ""
    @State private var hasFrontmatter = false
    @State private var problem: String?
    @State private var busy = false
    @State private var deleting = false

    private var current: String {
        AgentConfigMarkdown(frontmatter: frontmatter, markdown: markdown,
                                   hasFrontmatter: hasFrontmatter).content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind.title).appText(.title)
            Text(location).appText(.code).foregroundStyle(.secondary)
            HStack {
                Picker("File", selection: $selected) {
                    Text("Choose a file").tag(Optional<String>.none)
                    ForEach(files) { file in Text(file.path).tag(Optional(file.path)) }
                }
                .disabled(busy || current != original)
                TextField("New file name", text: $newName)
                Button("Add") { Task { await add() } }
                    .disabled(busy || newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if selected != nil {
                AgentConfigEditorFields(frontmatter: $frontmatter, markdown: $markdown)
                HStack {
                    if let problem { Text(problem).appText(.fine).tinted(.failure) }
                    Spacer()
                    Button("Discard changes") { pick(selected) }
                        .disabled(busy || current == original)
                    Button("Delete…", role: .destructive) { deleting = true }.disabled(busy)
                    Button("Save") { Task { await save() } }
                        .disabled(busy || current == original)
                }
            } else {
                Text("Add or choose a file to edit it.").appText(.supporting).foregroundStyle(.secondary)
                if let problem { Text(problem).appText(.fine).tinted(.failure) }
                Spacer()
            }
        }
        .padding(20)
        .task(id: kind) { await reload() }
        .onChange(of: selected) { _, path in pick(path) }
        .confirmationDialog("Delete this file?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete File", role: .destructive) { Task { await remove() } }
        } message: {
            Text("The selected file will be removed from \(location).")
        }
    }

    private func pick(_ path: String?) {
        let parts = AgentConfigMarkdown(files.first(where: { $0.path == path })?.content ?? "")
        frontmatter = parts.frontmatter
        markdown = parts.markdown
        hasFrontmatter = parts.hasFrontmatter
        original = parts.content
        problem = nil
    }

    private func reload() async {
        guard let listed = await load() else { problem = "Files could not be loaded."; return }
        files = listed
        if selected == nil || !listed.contains(where: { $0.path == selected }) { selected = listed.first?.path }
        pick(selected)
    }

    private func add() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = kind == .skills ? "\(name)/SKILL.md" : "\(name).md"
        guard !files.contains(where: { $0.path == path }) else { problem = "This file already exists."; return }
        let content = kind == .workflows ? "---\non: manual\n---\n\n" : "---\nname: \(name)\n---\n\n"
        busy = true
        problem = await saveFile(path, content, false)
        busy = false
        if problem == nil { newName = ""; selected = path; await reload() }
    }

    private func save() async {
        guard let selected else { return }
        busy = true
        problem = await saveFile(selected, current, false)
        busy = false
        if problem == nil { await reload() }
    }

    private func remove() async {
        guard let selected else { return }
        busy = true
        problem = await saveFile(selected, "", true)
        busy = false
        if problem == nil { self.selected = nil; await reload() }
    }
}

private struct AgentConfigEditorFields: View {
    @Binding var frontmatter: String
    @Binding var markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Frontmatter (YAML)").appText(.supporting).fontWeight(.semibold)
            TextEditor(text: $frontmatter).appText(.code).frame(minHeight: 120)
                .accessibilityLabel("Frontmatter YAML")
            Text("Markdown").appText(.supporting).fontWeight(.semibold)
            TextEditor(text: $markdown).appText(.code).frame(minHeight: 220)
                .accessibilityLabel("Markdown body")
        }
    }
}
