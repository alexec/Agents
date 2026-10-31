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

/// Skills, personas and workflows: one form with a file picker on the Mac, and on the Remote a
/// list of files that pushes to a screen per file (#2763).
/// While there are unsaved edits, nothing in the editor replaces them, and every way out asks
/// first (#2745): the Mac's page list through `unsaved`, the Remote's Back and sheet swipe.
struct AgentConfigFileEditor: View {
    let kind: DaemonAPI.AgentConfigEditorKind
    let location: String
    let load: @MainActor () async -> [DaemonAPI.AgentConfigEditorFile]?
    let saveFile: @MainActor (_ path: String, _ content: String, _ delete: Bool) async -> String?
    /// True while the open file has edits not saved, for a container that can leave the editor.
    var unsaved: Binding<Bool> = .constant(false)
    /// A file to open, such as a Needs a look row's skill (#2761); set back to nil once it is
    /// open, or when there is no such file. Edits not saved keep the open file.
    var open: Binding<String?> = .constant(nil)
    /// For `~/.agents`: say it is this Mac's and what goes to the other machines, as the Mac's
    /// Agent Configuration says at its top (#2766, #2704). False for a folder's `.agents`.
    var userScope = false

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

    private var dirty: Bool { current != original }

    private var current: String {
        AgentConfigMarkdown(frontmatter: frontmatter, markdown: markdown,
                                   hasFrontmatter: hasFrontmatter).content
    }

    var body: some View {
        #if os(iOS)
        AgentConfigFileList(kind: kind, location: location, load: load, saveFile: saveFile,
                            unsaved: unsaved, open: open, userScope: userScope)
        #else
        form
        #endif
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind.title).appText(.title)
            if userScope {
                VStack(alignment: .leading, spacing: 3) {
                    Text(UserScopeWords.thisMacOnly).appText(.supporting).fontWeight(.semibold)
                    Text(UserScopeWords.agentConfigurationFollows).appText(.fine).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
        .onChange(of: open.wrappedValue) { openAsked() }
        .onChange(of: dirty, initial: true) { _, now in unsaved.wrappedValue = now }
        .onDisappear { unsaved.wrappedValue = false }
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
        openAsked()
    }

    private func openAsked() {
        guard let path = open.wrappedValue, !files.isEmpty else { return }
        if !dirty, files.contains(where: { $0.path == path }) { selected = path }
        open.wrappedValue = nil
    }

    private func add() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let (path, content) = kind.newFile(named: name)
        guard !files.contains(where: { $0.path == path }) else { problem = "This file already exists."; return }
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

extension DaemonAPI.AgentConfigEditorKind {
    /// Where Add puts a file called `name`, and what it starts with.
    func newFile(named name: String) -> (path: String, content: String) {
        (self == .skills ? "\(name)/SKILL.md" : "\(name).md",
         self == .workflows ? "---\non: manual\n---\n\n" : "---\nname: \(name)\n---\n\n")
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

#if os(iOS)
/// The Remote's editor (#2763): the files as a list, + to add one, and a screen per file with
/// Save in its toolbar, as Notes and Settings draw a list of documents.
private struct AgentConfigFileList: View {
    let kind: DaemonAPI.AgentConfigEditorKind
    let location: String
    let load: @MainActor () async -> [DaemonAPI.AgentConfigEditorFile]?
    let saveFile: @MainActor (_ path: String, _ content: String, _ delete: Bool) async -> String?
    let unsaved: Binding<Bool>
    let open: Binding<String?>
    let userScope: Bool

    @State private var files: [DaemonAPI.AgentConfigEditorFile] = []
    @State private var loaded = false
    @State private var problem: String?
    @State private var adding = false
    @State private var newName = ""
    @State private var busy = false
    /// A file pushed by Add or by `open`, not by a tap on its row.
    @State private var pushed: String?

    var body: some View {
        Form {
            Section {
                ForEach(files) { file in
                    NavigationLink { screen(file) } label: { Text(file.path).appText(.code) }
                }
                if loaded && files.isEmpty {
                    Text("No files yet. Tap + to add one.").appText(.supporting).foregroundStyle(.secondary)
                }
                if let problem { Text(problem).appText(.fine).tinted(.failure) }
            } header: {
                Text(location).appText(.code).textCase(nil)
            } footer: {
                if userScope {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(UserScopeWords.thisMacOnly).fontWeight(.semibold)
                        Text(UserScopeWords.agentConfigurationFollows)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Paper.ground)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add File", systemImage: "plus") { newName = ""; adding = true }
                    .disabled(busy || !loaded)
            }
        }
        .navigationDestination(item: $pushed) { path in
            if let file = files.first(where: { $0.path == path }) { screen(file) }
        }
        .alert("Add a File", isPresented: $adding) {
            TextField("Name", text: $newName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Add") { Task { await add() } }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A new file in \(location).")
        }
        .task(id: kind) { await reload() }
        .onChange(of: open.wrappedValue) { openAsked() }
    }

    private func screen(_ file: DaemonAPI.AgentConfigEditorFile) -> some View {
        AgentConfigFileScreen(path: file.path, content: file.content, location: location,
                              saveFile: saveFile, unsaved: unsaved, changed: { await reload() })
    }

    private func reload() async {
        guard let listed = await load() else { problem = "Files could not be loaded."; return }
        files = listed
        problem = nil
        loaded = true
        openAsked()
    }

    private func openAsked() {
        guard let path = open.wrappedValue, loaded else { return }
        if !unsaved.wrappedValue, files.contains(where: { $0.path == path }) { pushed = path }
        open.wrappedValue = nil
    }

    private func add() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let (path, content) = kind.newFile(named: name)
        guard !files.contains(where: { $0.path == path }) else { problem = "This file already exists."; return }
        busy = true
        problem = await saveFile(path, content, false)
        busy = false
        if problem == nil { await reload(); pushed = path }
    }
}

/// One file's frontmatter and Markdown, with Save in the toolbar. Back and a swipe on the sheet
/// ask first while there are edits not saved, as Notes and Mail do (#2745).
private struct AgentConfigFileScreen: View {
    let path: String
    let location: String
    let saveFile: @MainActor (_ path: String, _ content: String, _ delete: Bool) async -> String?
    let unsaved: Binding<Bool>
    let changed: @MainActor () async -> Void

    @State private var frontmatter: String
    @State private var markdown: String
    @State private var hasFrontmatter: Bool
    @State private var original: String
    @State private var problem: String?
    @State private var busy = false
    @State private var deleting = false
    @State private var leaving: UnsavedLeave?
    @Environment(\.dismiss) private var dismiss

    init(path: String, content: String, location: String,
         saveFile: @escaping @MainActor (_ path: String, _ content: String, _ delete: Bool) async -> String?,
         unsaved: Binding<Bool>, changed: @escaping @MainActor () async -> Void) {
        self.path = path
        self.location = location
        self.saveFile = saveFile
        self.unsaved = unsaved
        self.changed = changed
        let parts = AgentConfigMarkdown(content)
        _frontmatter = State(initialValue: parts.frontmatter)
        _markdown = State(initialValue: parts.markdown)
        _hasFrontmatter = State(initialValue: parts.hasFrontmatter)
        _original = State(initialValue: parts.content)
    }

    private var current: String {
        AgentConfigMarkdown(frontmatter: frontmatter, markdown: markdown, hasFrontmatter: hasFrontmatter).content
    }

    private var dirty: Bool { current != original }

    var body: some View {
        Form {
            Section("Frontmatter (YAML)") {
                TextEditor(text: $frontmatter).appText(.code).frame(minHeight: 120)
                    .accessibilityLabel("Frontmatter YAML")
            }
            Section("Markdown") {
                TextEditor(text: $markdown).appText(.code).frame(minHeight: 220)
                    .accessibilityLabel("Markdown body")
            }
            if let problem {
                Section { Text(problem).appText(.fine).tinted(.failure) }
            }
            Section {
                Button("Discard Changes") { revert() }.disabled(busy || !dirty)
                Button("Delete File", role: .destructive) { deleting = true }.disabled(busy)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Paper.ground)
        .navigationTitle(path)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(dirty)
        .interactiveDismissDisabled(dirty)
        .toolbar {
            if dirty {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back", systemImage: "chevron.backward") { leaving = UnsavedLeave { dismiss() } }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }.disabled(busy || !dirty)
            }
        }
        .discardUnsavedQuestion($leaving)
        .confirmationDialog("Delete this file?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete File", role: .destructive) { Task { await remove() } }
        } message: {
            Text("\(path) will be removed from \(location).")
        }
        .onChange(of: dirty, initial: true) { _, now in unsaved.wrappedValue = now }
        .onDisappear { unsaved.wrappedValue = false }
    }

    private func revert() {
        let parts = AgentConfigMarkdown(original)
        frontmatter = parts.frontmatter
        markdown = parts.markdown
        hasFrontmatter = parts.hasFrontmatter
        problem = nil
    }

    private func save() async {
        let saving = current
        busy = true
        problem = await saveFile(path, saving, false)
        busy = false
        if problem == nil { original = saving; await changed() }
    }

    private func remove() async {
        busy = true
        problem = await saveFile(path, "", true)
        busy = false
        if problem == nil { unsaved.wrappedValue = false; dismiss(); await changed() }
    }
}
#endif
