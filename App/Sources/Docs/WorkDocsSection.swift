import AgentsKitCore
import SwiftUI

/// The Docs section of an issue's and a PR's Work page's side panel (#3322, spec 3319; #4400), as the web page's
/// WorkDocs: the docs its body names, then the docs most like its title (`docs/search`, a search a
/// word). Each opens the doc's page. Mac + web, so not on the Remote (#2796).
struct WorkDocsSection: View {
    @Environment(AppModel.self) private var model
    let item: DaemonAPI.ForgeItem
    let text: String
    let asked: Int

    @State private var linked: [DaemonAPI.Doc]?
    @State private var related: [DaemonAPI.Doc]?

    private struct Ask: Equatable {
        var ref: String
        var body: String
        var title: String
        var asked: Int
    }

    var body: some View {
        Group {
            if !model.docsMachines.isEmpty {
                // A section of the page's side panel (#4400): the docs it names, then those like it.
                WorkSideSection(title: "Docs") {
                    if let linked, let related {
                        if linked.isEmpty, related.isEmpty { WorkSideNone(words: "None") }
                        ForEach(linked) { row($0) }
                        if !related.isEmpty {
                            Text("Like it").appText(.fine).foregroundStyle(.secondary)
                                .padding(.top, linked.isEmpty ? 0 : 4)
                            ForEach(related) { row($0) }
                        }
                    } else {
                        Text("Finding its docs…").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: Ask(ref: item.node.ref, body: text, title: item.title, asked: asked)) { await load() }
    }

    private func row(_ doc: DaemonAPI.Doc) -> some View {
        Button { model.showDocs(DocsPlace(ref: doc.ref)) } label: {
            // The panel is narrow: the title goes under the doc's name.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(icon: "doc.text").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(DocsList.shortForm(doc)).monospaced(doc.path != nil).lineLimit(1).truncationMode(.middle)
                    if let beside = DocsList.titleBeside(doc) {
                        Text(beside).appText(.fine).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(doc.ref)
    }

    private func load() async {
        let machines = model.docsMachines
        let refs = DocsList.linkedRefs(body: text, itemRef: item.node.ref)
        var found: [DaemonAPI.Doc] = []
        // Each named doc from the first machine that has it; one it cannot find is left out.
        for ref in refs {
            for machine in machines {
                guard let got = try? await model.docs(DaemonAPI.Method.docsRead, DaemonAPI.DocsReadRequest(ref: ref, from: 1, to: 1),
                                                      returning: DaemonAPI.DocsReading.self, on: machine.id) else { continue }
                if model.docsList.listedOn[got.doc.ref] == nil { model.docsList.listedOn[got.doc.ref] = machine.id }
                if !found.contains(where: { $0.ref == got.doc.ref }) { found.append(got.doc) }
                break
            }
        }
        guard !Task.isCancelled else { return }
        var searches: [[DaemonAPI.DocsSearchResult]] = []
        for word in DocsList.searchWords(item.title) {
            var results: [DaemonAPI.DocsSearchResult] = []
            for machine in machines {
                let got = try? await model.docs(DaemonAPI.Method.docsSearch, DaemonAPI.DocsSearchRequest(query: word, limit: 20),
                                                returning: DaemonAPI.DocsSearch.self, on: machine.id)
                for r in got?.results ?? [] where model.docsList.listedOn[r.doc.ref] == nil {
                    model.docsList.listedOn[r.doc.ref] = machine.id
                }
                results += got?.results ?? []
            }
            searches.append(results)
        }
        guard !Task.isCancelled else { return }
        linked = found
        related = DocsList.related(searches, leaving: Set(found.map(\.ref)))
    }
}
