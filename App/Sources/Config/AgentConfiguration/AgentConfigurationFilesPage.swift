import AgentsKitCore
import SwiftUI

struct AgentConfigurationFilesPage: View {
    @Environment(AppModel.self) private var model
    let place: AgentsPlace
    let kind: DaemonAPI.AgentConfigEditorKind
    var unsaved: Binding<Bool> = .constant(false)
    /// The skills the Overview's Needs a look sends here (#2761), each opening its file.
    var looks: [DaemonAPI.Look] = []
    @State private var showingSkillCatalogue = false
    @State private var opening: String?

    private var folder: URL? {
        if case .folder(let folder) = place { return folder }
        return nil
    }

    private var host: MachineRef {
        folder == nil ? .mac : model.selectedFolderHost
    }

    var body: some View {
        VStack(spacing: 0) {
            if kind == .skills {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Spacer()
                        Button("Install or update skills…") { showingSkillCatalogue = true }.buttonStyle(.paper)
                    }
                    if !looks.isEmpty {
                        SharedSectionLabel("Needs a look")
                        ForEach(looks) { look in
                            LookRow(look: look) { opening = "\(look.item)/SKILL.md" }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            AgentConfigFileEditor(kind: kind, location: "\(place.folderName)/\(kind.rawValue)",
                                  load: { await model.agentConfigEditorFiles(on: host, folder: folder, kind: kind) },
                                  saveFile: { path, content, delete in
                                      await model.saveAgentConfigEditorFile(on: host, folder: folder, kind: kind,
                                                                           path: path, content: content, delete: delete)
                                  },
                                  unsaved: unsaved, open: $opening)
        }
        // A file asked for from elsewhere, such as a workflow page's Edit File… (#2803).
        .onChange(of: model.agentConfigFileAsked, initial: true) { _, asked in
            guard let asked, asked.kind == kind,
                  asked.folder?.standardizedFileURL == folder?.standardizedFileURL else { return }
            opening = asked.path
            model.agentConfigFileAsked = nil
        }
        .sheet(isPresented: $showingSkillCatalogue) {
            AgentsSetupPage { AgentsSkillsSection(place: place) }
                .frame(minWidth: 650, minHeight: 500)
        }
    }
}

/// A file to open in Agent Configuration's editor (#2803): its kind, its path inside that
/// kind's folder, and the folder whose `.agents` it is in, or nil for `~/.agents`.
struct AgentConfigFileAsk: Equatable {
    var folder: URL?
    var kind: DaemonAPI.AgentConfigEditorKind
    var path: String
}
