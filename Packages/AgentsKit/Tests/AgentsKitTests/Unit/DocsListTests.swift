import Foundation
import Testing
@testable import AgentsKitCore

/// Docs' list (#3321), as Web/test/docs.test.mjs has it on the web page.
@Suite("Docs list")
struct DocsListTests {
    typealias Doc = DaemonAPI.Doc
    typealias Source = DaemonAPI.DocsSource

    static let now = Date(timeIntervalSince1970: 1_793_700_000)
    static func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    static let agents = Source(id: "/Users/a/Agents", kind: .folder, name: "Agents", folder: "/Users/a/Agents")
    static let confluence = Source(id: "mcp:confluence", kind: .connector, name: "confluence", folder: agents.id)
    static let notion = Source(id: "mcp:notion", kind: .connector, name: "notion", folder: agents.id, state: .notMapped)

    static func doc(_ path: String, _ title: String, _ hours: Double) -> Doc {
        Doc(ref: "github:alexec/agents/doc/\(path)", title: title, source: agents.id, folder: agents.id, path: path,
            updated: ago(hours))
    }

    static let spec = doc("specs/3319-docs/spec.md", "Docs, first-class beside Work", 2)
    static let plans = doc("specs/3265-work-plans/spec.md", "Plans in Work", 24)
    static let payments = Doc(ref: "confluence:acme.atlassian.net/1", title: "Payments: requirements", source: "mcp:confluence",
                              url: "https://acme/1", updated: ago(168))
    static let mac = DocsList.HostDocs(host: .mac, name: "This Mac", docs: [
        spec, plans, doc("docs/explanation/leases.md", "Leases", 72), doc("README.md", "Agents", 120), payments,
    ], sources: [agents, confluence, notion])

    @Test func aFoldersDocsGoBySubfolderItsTopLastThenEachConnector() throws {
        let groups = DocsList.groups([Self.mac], sort: .updated)
        try #require(groups.count == 3)
        let (folder, confluence, notion) = (groups[0], groups[1], groups[2])
        try #require(folder.shelves.count == 3)
        let specs = folder.shelves[1]
        #expect(groups.map(\.row.heading) == ["Agents", "confluence", "notion"])
        #expect(folder.shelves.map(\.dir) == ["docs/", "specs/", ""])
        #expect(specs.docs.map { DocsList.underShelf($0, "specs/") } == ["3319-docs/spec.md", "3265-work-plans/spec.md"])
        #expect(confluence.shelves.map(\.docs.count) == [1])
        #expect(notion.shelves.isEmpty)
        #expect(DocsList.problem(Self.notion) == "not mapped")
    }

    @Test func sortByTitleAndOneSource() throws {
        let folder = try #require(DocsList.groups([Self.mac], sort: .title).first)
        try #require(folder.shelves.count == 3)
        let specs = folder.shelves[1].docs.map(\.title)
        #expect(specs == ["Docs, first-class beside Work", "Plans in Work"])
        #expect(DocsList.groups([Self.mac], sort: .updated, only: "mcp:confluence").map(\.row.key) == ["mcp:confluence"])
    }

    @Test func oneConnectorOnTwoMachinesIsOneSource() {
        let studio = DocsList.HostDocs(host: MachineRef(rawValue: "studio"), name: "Studio",
                                       sources: [Source(id: "/Users/a/Agents", kind: .folder, name: "Agents"), Self.confluence])
        let rows = DocsList.sources([Self.mac, studio])
        #expect(rows.map(\.heading) == ["Agents (This Mac)", "Agents (Studio)", "confluence", "notion"])
        #expect(rows.filter { $0.key == "mcp:confluence" }.map(\.host) == [.mac])
    }

    @Test func aProjectsClonesOnTwoMachinesAreOneSourceSaidByItsName() throws {
        let studio = MachineRef(rawValue: "studio")
        let clone = Source(id: "/home/a/agents", kind: .folder, name: "agents", folder: "/home/a/agents")
        let notes = Source(id: "/home/a/notes", kind: .folder, name: "notes", folder: "/home/a/notes")
        let other = DocsList.HostDocs(host: studio, name: "Studio", docs: [
            Doc(ref: "github:alexec/agents/doc/README.md", title: "Agents", source: clone.id, folder: clone.id, path: "README.md"),
        ], sources: [clone, notes])
        let app = DocsList.Project(id: "p1", name: "Agents app")
        let projectOf: DocsList.ProjectOf = { host, folder in
            (host == .mac && folder == Self.agents.id) || (host == studio && folder == clone.id) ? app : nil
        }
        let rows = DocsList.sources([Self.mac, other], projectOf: projectOf)
        try #require(rows.count == 4)
        #expect(rows.map(\.key) == ["project:p1", "studio|/home/a/notes", "mcp:confluence", "mcp:notion"])
        #expect(rows.map(\.heading) == ["Agents app", "notes (Studio)", "confluence", "notion"])
        #expect(rows.first?.host == .mac)
        // A connector is under the project of the folder whose mcp.json adds it.
        #expect(rows[2].project == app)
        #expect(DocsList.projects(rows) == [app])
        let one = DocsList.groups([Self.mac, other], sort: .updated, projectOf: projectOf, project: "p1")
        #expect(one.map(\.row.key) == ["project:p1", "mcp:confluence", "mcp:notion"])
        // The clone's README is the same ref as the Mac's, so it is there once, the Mac's.
        #expect(try #require(one.first).shelves.flatMap(\.docs).count == 4)
        #expect(rows[0].members.map(\.host) == [.mac, studio])
        #expect(DocsList.searchSources(rows[0], on: studio) == [clone.id])
        #expect(DocsList.searchSources(rows[2], on: studio) == ["mcp:confluence"])
    }

    @Test func aProjectWithOneFolderLooksAsTheFolderDoes() {
        let rows = DocsList.sources([Self.mac]) { _, folder in folder == Self.agents.id ? .init(id: "p1", name: "Agents") : nil }
        #expect(rows.map(\.heading) == ["Agents", "confluence", "notion"])
    }

    @Test func searchShowsOnlyResultsInASourceTheListShows() {
        let studio = MachineRef(rawValue: "studio")
        let clone = Source(id: "/home/a/agents", kind: .folder, name: "agents", folder: "/home/a/agents")
        let rows = DocsList.sources([Self.mac, .init(host: studio, name: "Studio", sources: [clone])]) { _, folder in
            folder == nil ? nil : .init(id: "p1", name: "Agents")
        }
        func found(_ host: MachineRef, _ source: String, _ ref: String) -> DocsList.Result {
            .init(host: host, result: .init(doc: Doc(ref: ref, title: ref, source: source), matches: []))
        }
        let kept = DocsList.results([found(.mac, Self.agents.id, "a"), found(studio, clone.id, "b"),
                                     found(studio, "/home/a/notes", "n"), found(studio, "mcp:confluence", "c")], in: rows)
        #expect(kept.map(\.result.doc.ref) == ["a", "b", "c"])
    }

    @Test func aRowSaysThePathOfAFolderDocAndTheTitleOfAConnectorDoc() {
        #expect(DocsList.shortForm(Self.spec) == "specs/3319-docs/spec.md")
        #expect(DocsList.shortForm(Self.payments) == "Payments: requirements")
        #expect(DocsList.titleBeside(Self.spec) == "Docs, first-class beside Work")
        #expect(DocsList.titleBeside(Self.doc("NOTES.md", "NOTES.md", 1)) == nil)
        #expect(DocsList.updatedWords(Self.spec, now: Self.now) == "2h ago")
        #expect(DocsList.updatedWords(Self.payments, now: Self.now) == "1w ago")
        #expect(DocsList.isFolderDoc(Self.spec))
        #expect(!DocsList.isFolderDoc(Self.payments))
    }

    @Test func aConnectorDocOpensInItsVendorsApp() {
        #expect(DocsList.vendorName("confluence:acme.atlassian.net/1") == "Confluence")
        #expect(DocsList.vendorName("gdrive:1AbC") == "Google Drive")
        #expect(DocsList.vendorName("mcp:wiki/handbook-42") == "wiki")
        #expect(DocsList.windowAddress("notion:1f2e") == "agents://docs/notion:1f2e")
    }

    @Test func searchResultsFromEveryMachineEachDocOnceTheMostMatchesFirst() {
        let a = DaemonAPI.DocsSearchResult(doc: Self.spec, matches: [.init(line: 3, snippet: "docs")])
        let b = DaemonAPI.DocsSearchResult(doc: Self.plans, matches: [.init(line: 1, snippet: "x"), .init(line: 9, snippet: "y")])
        let merged = DocsList.merged([(.mac, [a, b]), (MachineRef(rawValue: "studio"), [a])])
        #expect(merged.map(\.result.doc.title) == ["Plans in Work", "Docs, first-class beside Work"])
        #expect(merged.map(\.host) == [.mac, .mac])
    }

    @Test func aPlaceOnTheListHasNoLine() {
        #expect(DocsPlace(line: 4).line == nil)
        #expect(DocsPlace(ref: "notion:1", line: 4).line == 4)
    }
}
