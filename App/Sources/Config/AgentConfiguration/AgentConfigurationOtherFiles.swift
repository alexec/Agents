import AgentsKitCore
import SwiftUI

/// Frame G: everything else in `~/.agents` or a folder's `.agents`, with what (if
/// anything) uses it. Nothing is hidden, so the pages are the whole folder.
struct AgentConfigurationOtherFiles: View {
    @Environment(AppModel.self) private var model
    let place: AgentsPlace
    let snapshot: DaemonAPI.SharedSnapshot
    @State private var managingPersonas = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SharedPageHeader(title: "Other files", path: snapshot.home) {
                    Button("Reveal in Finder") { SharedFiles.reveal(snapshot.home) }.buttonStyle(.paper)
                }
                Button("Manage personas…") { managingPersonas = true }.buttonStyle(.paper)
                if snapshot.otherFiles.isEmpty {
                    Text("Nothing else in \(place.folderName).").appText(.fine).foregroundStyle(.secondary)
                }
                ForEach(snapshot.otherFiles) { file in
                    let path = snapshot.home + "/" + file.path
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.path + (file.kind == .git ? "/" : "")).appText(.code)
                            Text(Self.use(file.kind, in: place)).appText(.fine).foregroundStyle(.secondary)
                        }
                        Spacer()
                        SharedChip(text: file.kind.rawValue)
                        Button("Reveal") { SharedFiles.reveal(path) }.buttonStyle(.paper)
                        if file.kind == .unused {
                            Button("Edit") { SharedFiles.open(path) }.buttonStyle(.paper)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .paperRaised(in: RoundedRectangle(cornerRadius: Paper.Radius.control))
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $managingPersonas) { personaManager }
    }

    @ViewBuilder private var personaManager: some View {
        switch place {
        case .you:
            PersonaManagerSheet(host: .mac, folder: URL(filePath: snapshot.home), personalOnly: true)
        case .folder(let folder):
            PersonaManagerSheet(host: model.selectedFolderHost, folder: folder)
        }
    }

    static func use(_ kind: DaemonAPI.OtherFile.Kind, in place: AgentsPlace) -> String {
        switch kind {
        case .persona: "A persona: picked when an agent starts"
        case .git: "\(place.folderName) is a git repository"
        case .managed: "Kept by the skills installer; the app leaves it alone"
        case .app: "The app’s own: the folder’s settings, pins and workflows, and what it keeps as it works"
        case .unused:
            switch place {
            case .you: "Not read by any agent"
            case .folder: "Not read by the app; an agent here can still open it"
            }
        }
    }
}
