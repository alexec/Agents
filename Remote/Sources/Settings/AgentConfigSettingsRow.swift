import AgentsKitCore
import SwiftUI

struct AgentConfigSettingsRow: View {
    let kind: DaemonAPI.AgentConfigEditorKind

    var body: some View {
        SettingsPageLink(kind.title, systemImage: symbol) {
            RemoteAgentConfigEditor(kind: kind, folder: nil)
                .navigationTitle(kind.title)
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

    var body: some View {
        AgentConfigFileEditor(kind: kind, location: folder == nil ? "~/.agents/\(kind.rawValue)" : ".agents/\(kind.rawValue)",
                              load: { await model.agentConfigEditorFiles(in: folder, kind: kind) },
                              saveFile: { path, content, delete in
                                  await model.saveAgentConfigEditorFile(in: folder, kind: kind,
                                                                        path: path, content: content, delete: delete)
                              },
                              // `~/.agents` is the Mac's: say so, and what goes to the other machines (#2766, #2704).
                              userScope: folder == nil)
    }
}

struct RemoteFolderAgentConfiguration: View {
    let folder: URL

    var body: some View {
        NavigationStack {
            List {
                ForEach(DaemonAPI.AgentConfigEditorKind.allCases, id: \.self) { kind in
                    NavigationLink(kind.title) { RemoteAgentConfigEditor(kind: kind, folder: folder) }
                }
            }
            .navigationTitle("Agent Configuration")
        }
    }
}
