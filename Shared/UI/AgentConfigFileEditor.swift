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
/// While there are unsaved edits, nothing in the editor replaces them, and every way out asks
/// first (#2745): the Mac's page list through `unsaved`, the Remote's Back and sheet swipe here.
struct AgentConfigFileEditor: View {
    let kind: DaemonAPI.AgentConfigEditorKind
    let location: String
    let load: @MainActor () async -> [DaemonAPI.AgentConfigEditorFile]?
    let saveFile: @MainActor (_ path: String, _ content: String, _ delete: Bool) async -> String?
    /// True while the open file has edits not saved, for a container that can leave the editor.
    var unsaved: Binding<Bool> = .constant(false)

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
    #if os(iOS)
    @State private var leaving: UnsavedLeave?
    @Environment(\.dismiss) private var dismiss
    #endif

    private var dirty: Bool { current != original }

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
                .disabled(busy || dirty)
                TextField("New file name", text: $newName)
                Button("Add") { Task { await add() } }
                    .disabled(busy || dirty || newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if selected != nil {
                AgentConfigEditorFields(frontmatter: $frontmatter, markdown: $markdown)
                HStack {
                    if let problem { Text(problem).appText(.fine).tinted(.failure) }
                    Spacer()
                    Button("Discard changes") { pick(selected) }
                        .disabled(busy || !dirty)
                    Button("Delete…", role: .destructive) { deleting = true }.disabled(busy)
                    Button("Save") { Task { await save() } }
                        .disabled(busy || !dirty)
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
        .onChange(of: dirty, initial: true) { _, now in unsaved.wrappedValue = now }
        .onDisappear { unsaved.wrappedValue = false }
        #if os(iOS)
        // Back and a swipe on the sheet would drop the edits: ask first, as Notes and Mail do.
        .navigationBarBackButtonHidden(dirty)
        .interactiveDismissDisabled(dirty)
        .toolbar {
            if dirty {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", systemImage: "chevron.backward") { leaving = UnsavedLeave { dismiss() } }
                }
            }
        }
        .discardUnsavedQuestion($leaving)
        #endif
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

/// What the editor and its containers say when unsaved edits would be lost (#2745).
enum AgentConfigEditorWords {
    static let discardQuestion = "Discard unsaved changes?"
    static let discardMessage = "Your changes to this file have not been saved."
    static let discard = "Discard Changes"
    static let keepEditing = "Keep Editing"
}

/// A way out of the editor that waits for the person's answer: taken on Discard Changes.
struct UnsavedLeave: Identifiable {
    let id = UUID()
    let go: () -> Void
}

extension Binding where Value == UnsavedLeave? {
    /// Takes `go` at once when nothing is unsaved, or asks first (#2745).
    func leave(unsaved: Bool, _ go: @escaping () -> Void) {
        if unsaved { wrappedValue = UnsavedLeave(go: go) } else { go() }
    }
}

extension View {
    /// "Discard unsaved changes?" while `leaving` holds a way out: Discard Changes takes it,
    /// Keep Editing and Escape stay.
    func discardUnsavedQuestion(_ leaving: Binding<UnsavedLeave?>) -> some View {
        confirmationDialog(AgentConfigEditorWords.discardQuestion,
                           isPresented: Binding(get: { leaving.wrappedValue != nil },
                                                set: { if !$0 { leaving.wrappedValue = nil } }),
                           titleVisibility: .visible, presenting: leaving.wrappedValue) { leave in
            Button(AgentConfigEditorWords.discard, role: .destructive) { leave.go() }
            Button(AgentConfigEditorWords.keepEditing, role: .cancel) {}
        } message: { _ in
            Text(AgentConfigEditorWords.discardMessage)
        }
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
