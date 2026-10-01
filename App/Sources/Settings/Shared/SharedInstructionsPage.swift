import AgentsKitCore
#if !AGENTS_STORE
import AgentsKit
#endif
import SwiftUI

/// Frame G: everything else in `~/.agents`, with what (if anything) uses it. Nothing is
/// hidden, so the tab is the whole folder.
struct SharedOtherFilesPage: View {
    let snapshot: DaemonAPI.SharedSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                SharedPageHeader(title: "Other files", path: snapshot.home) {
                    Button("Reveal in Finder") { SharedFiles.reveal(snapshot.home) }.buttonStyle(.paper)
                }
                if snapshot.otherFiles.isEmpty {
                    Text("Nothing else in ~/.agents.").appText(.fine).foregroundStyle(.secondary)
                }
                ForEach(snapshot.otherFiles) { file in
                    let path = snapshot.home + "/" + file.path
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.path + (file.kind == .git ? "/" : "")).appText(.code)
                            Text(Self.use(file.kind)).appText(.fine).foregroundStyle(.secondary)
                        }
                        Spacer()
                        SharedChip(text: file.kind.rawValue)
                        Button("Reveal") { SharedFiles.reveal(path) }.buttonStyle(.paper)
                        if file.kind == .persona || file.kind == .unused {
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
    }

    static func use(_ kind: DaemonAPI.OtherFile.Kind) -> String {
        switch kind {
        case .persona: "A persona: agents can be asked to adopt it"
        case .git: "~/.agents is a git repository"
        case .managed: "Kept by the skills installer; the app leaves it alone"
        case .unused: "Not read by any agent"
        }
    }
}
