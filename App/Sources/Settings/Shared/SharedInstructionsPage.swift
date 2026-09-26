import AgentsKit
import SwiftUI

/// Frame F: the one `AGENTS.md`, as agents read it, and where each runtime reads it from.
/// A file that was already the person's and was left alone is shown as what that runtime
/// reads instead.
struct SharedInstructionsPage: View {
    let snapshot: DaemonAPI.SharedSnapshot
    @State private var text = ""

    private var path: String { snapshot.instructions?.path ?? snapshot.home + "/AGENTS.md" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SharedPageHeader(title: "Instructions", path: path) {
                    Button("Edit AGENTS.md") { SharedFiles.open(path) }.buttonStyle(.paper)
                }
                Text(text)
                    .appText(.supporting)
                    .textSelection(.enabled)
                    .lineLimit(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Paper.raised, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Paper.rule, lineWidth: 1))
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    GridRow {
                        Text("Runtime"); Text("Reads"); Text("Gets AGENTS.md")
                    }
                    .appText(.fine).foregroundStyle(.secondary)
                    ForEach(snapshot.runtimes) { runtime in
                        let reach = snapshot.instructions?.reach[runtime.id]
                        GridRow(alignment: .firstTextBaseline) {
                            Text(runtime.name)
                            Text(Self.reads(reach)).appText(.code).foregroundStyle(.secondary)
                            Text(Self.mark(reach))
                                .foregroundStyle(reach?.gets == true ? SharedInk.reach : .secondary)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(runtime.name): \(Self.reads(reach)). \(SharedReachList.line(reach ?? .unchecked(nil)))")
                    }
                }
            }
            .padding(20)
        }
        .task(id: path) {
            text = (try? String(contentsOf: URL(filePath: path), encoding: .utf8)) ?? "No AGENTS.md yet."
        }
    }

    static func reads(_ reach: DaemonAPI.Reach?) -> String {
        switch reach {
        case .gets(let note): note
        case .ownCopy(let path): "\(SharedFiles.tilde(path)), its own file, left alone"
        case .leftOut(let note), .noWay(let note): note
        case .unchecked(let note): note ?? "not checked yet"
        case nil: ""
        }
    }

    static func mark(_ reach: DaemonAPI.Reach?) -> String {
        switch reach {
        case .gets: "✓"
        case .unchecked: "?"
        default: "—"
        }
    }
}

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
                    .background(Paper.raised, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Paper.rule, lineWidth: 1))
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
