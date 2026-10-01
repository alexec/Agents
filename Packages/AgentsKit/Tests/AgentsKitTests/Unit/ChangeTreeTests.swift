import Foundation
import Testing
@testable import AgentsKitCore

@Suite("The Changes tree")
struct ChangeTreeTests {
    private func file(_ relative: String, _ state: ChangeState = .modified, added: Int? = 1,
                      removed: Int? = 0, oldPath: String? = nil) -> ChangedFile {
        ChangedFile(path: "/repo/" + relative, relativePath: relative, source: .seen, state: state,
                    added: added, removed: removed, oldPath: oldPath.map { "/repo/" + $0 })
    }

    private func names(_ lines: [ChangeTree.Line]) -> [String] {
        lines.map { line in
            let indent = String(repeating: "  ", count: line.depth)
            switch line.node {
            case .folder(let name, _, _, _): return indent + name + "/"
            case .file(let file): return indent + file.fileName
            }
        }
    }

    @Test func foldersComeFirstAndAOneFolderChainFoldsIntoOneLine() {
        let tree = ChangeTree.build([
            file("notes.txt", .untracked),
            file("App/Sources/Sidebar/ChangesPane.swift"),
            file("App/Sources/Chat/TurnView.swift"),
            file("Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentChanges.swift"),
            file("App/Sources/Sidebar/ChangeRow.swift", .deleted),
            file("docs/explanation/changes-pane.md", .renamed),
        ])
        #expect(names(ChangeTree.lines(tree, collapsed: [])) == [
            "App/Sources/",
            "  Chat/",
            "    TurnView.swift",
            "  Sidebar/",
            "    ChangeRow.swift",
            "    ChangesPane.swift",
            "docs/explanation/",
            "  changes-pane.md",
            "Packages/AgentsKit/Sources/AgentsKitCore/Model/",
            "  AgentChanges.swift",
            "notes.txt",
        ])
    }

    @Test func aFolderWithAFileBesideItsFolderDoesNotFold() {
        let tree = ChangeTree.build([file("a/b/c.swift"), file("a/d.swift")])
        #expect(names(ChangeTree.lines(tree, collapsed: [])) == ["a/", "  b/", "    c.swift", "  d.swift"])
    }

    @Test func aClosedFolderHidesWhatIsInItByItsWholePath() {
        let tree = ChangeTree.build([file("App/Sources/Chat/T.swift"), file("App/Sources/Sidebar/S.swift")])
        #expect(names(ChangeTree.lines(tree, collapsed: ["App/Sources/Chat"])) ==
                ["App/Sources/", "  Chat/", "  Sidebar/", "    S.swift"])
    }

    @Test func everyFolderCarriesWhatChangedUnderIt() throws {
        let tree = ChangeTree.build([
            file("a/b/one.swift", added: 10, removed: 2),
            file("a/two.swift", .deleted, added: 0, removed: 5),
            file("a/image.png", .binary, added: nil, removed: nil),
        ])
        guard case .folder(_, _, let children, let totals) = try #require(tree.first) else {
            Issue.record("expected a folder"); return
        }
        #expect(totals == ChangeTree.Totals(added: 10, removed: 7, files: 3))
        guard case .folder(_, _, _, let inner) = try #require(children.first) else {
            Issue.record("expected a folder"); return
        }
        #expect(inner == ChangeTree.Totals(added: 10, removed: 2, files: 1))
    }

    @Test func aFileOutsideTheFolderSitsUnderItsWholePath() {
        let outside = ChangedFile(path: "/tmp/x/a.txt", source: .reported, state: .modified,
                                  added: 1, removed: 1, outsideFolder: true)
        let tree = ChangeTree.build([outside, file("b.swift")])
        #expect(names(ChangeTree.lines(tree, collapsed: [])) == ["/tmp/x/", "  a.txt", "b.swift"])
    }

    @Test func theFilesPaneFindsAChangeAndEveryFolderAboveIt() {
        let index = ChangeTree.Index([file("App/Sources/a.swift", added: 3, removed: 1),
                                      file("App/b.swift", added: 2, removed: 0)])
        #expect(index.files["/repo/App/Sources/a.swift"]?.added == 3)
        #expect(index.folders["/repo/App"] == ChangeTree.Totals(added: 5, removed: 1, files: 2))
        #expect(index.folders["/repo/App/Sources"] == ChangeTree.Totals(added: 3, removed: 1, files: 1))
        #expect(index.folders["/repo"]?.files == 2)
    }

    @Test func voiceOverHearsTheStatusInWords() {
        var renamed = file("docs/explanation/changes-pane.md", .renamed, added: 9, removed: 3,
                           oldPath: "docs/explanation/changes.md")
        renamed.editCount = 1
        renamed.source = .reportedAndSeen
        #expect(ChangeWords.label(renamed) ==
                "changes-pane.md, renamed from docs/explanation/changes.md, 9 lines added, 3 removed, 1 edit")
        #expect(ChangeWords.label(file("ChangeRow.swift", .deleted, added: 0, removed: 21)) ==
                "ChangeRow.swift, deleted, 21 lines removed, git saw it in the folder")
        #expect(ChangeWords.label(file("notes.txt", .untracked, added: 6, removed: 0)) ==
                "notes.txt, untracked, not in git, 6 lines added, git saw it in the folder")
        #expect(ChangeWords.label(ChangeTree.Totals(added: 186, removed: 68, files: 4)) ==
                "4 changed files, 186 lines added, 68 removed")
        #expect(ChangeWords.help(renamed) == "Renamed from docs/explanation/changes.md · 1 edit")
    }
}
