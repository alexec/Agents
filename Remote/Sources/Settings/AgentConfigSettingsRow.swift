import AgentsKitCore
import SwiftUI

struct AgentConfigSettingsRow: View {
    let kind: DaemonAPI.AgentConfigEditorKind

    var body: some View {
        // Not a SettingsPageLink: the editor is a list of its own, not a row in a Form (#2763).
        NavigationLink {
            RemoteAgentConfigEditor(kind: kind, folder: nil)
        } label: {
            Label(kind.title, systemImage: symbol)
        }
    }

    private var symbol: String {
        switch kind {
        case .skills: "sparkles.rectangle.stack"
        case .personas: "person.crop.rectangle.stack"
        case .workflows: "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }
}

struct RemoteAgentConfigEditor: View {
    @Environment(RemoteModel.self) private var model
    let kind: DaemonAPI.AgentConfigEditorKind
    let folder: URL?
    /// A file to push once the list is read, such as a workflow page's Edit File… (#2803).
    var open: Binding<String?> = .constant(nil)

    var body: some View {
        AgentConfigFileEditor(kind: kind, location: folder == nil ? "~/.agents/\(kind.rawValue)" : ".agents/\(kind.rawValue)",
                              load: { await model.agentConfigEditorFiles(in: folder, kind: kind) },
                              saveFile: { path, content, delete in
                                  await model.saveAgentConfigEditorFile(in: folder, kind: kind,
                                                                        path: path, content: content, delete: delete)
                              },
                              open: open,
                              // `~/.agents` is the Mac's: say so, and what goes to the other machines (#2766, #2704).
                              userScope: folder == nil)
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct RemoteFolderAgentConfiguration: View {
    @Environment(\.dismiss) private var dismiss
    let folder: URL

    var body: some View {
        NavigationStack {
            List {
                ForEach(DaemonAPI.AgentConfigEditorKind.allCases, id: \.self) { kind in
                    NavigationLink(kind.title) { RemoteAgentConfigEditor(kind: kind, folder: folder) }
                }
            }
            .navigationTitle("Agent Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// A workflow's file in the Workflows editor (#2803), over its page, as the folder's Agent
/// Configuration… sheet is: the list for yours or the folder's, with the file pushed.
struct RemoteWorkflowFileEditor: View {
    @Environment(\.dismiss) private var dismiss
    let folder: URL?
    @State private var opening: String?

    init(folder: URL?, opening: String) {
        self.folder = folder
        _opening = State(initialValue: opening)
    }

    var body: some View {
        NavigationStack {
            RemoteAgentConfigEditor(kind: .workflows, folder: folder, open: $opening)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}
