import Foundation
import Testing
@testable import AgentsKit

/// The one place in this feature where a mistake writes to the wrong place on somebody's
/// disk. Refusal is the default and every awkward case is here.
@Suite("What an agent may reach")
struct FolderScopeTests {
    private func sandbox() throws -> URL {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "FolderScopeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Resolved, because /tmp is itself a symlink on a Mac and the tests compare paths.
        return root.resolvingSymlinksInPath()
    }

    @Test func aFileInTheFolderIsAllowed() throws {
        let root = try sandbox()
        let file = root.appending(path: "notes.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        #expect(FolderScope(folders: [root]).allows(file.path))
    }

    @Test func aFileOutsideEveryFolderIsRefused() throws {
        let root = try sandbox()
        let elsewhere = try sandbox().appending(path: "secret.txt")
        try "no".write(to: elsewhere, atomically: true, encoding: .utf8)
        #expect(!FolderScope(folders: [root]).allows(elsewhere.path))
    }

    @Test func climbingOutWithDotDotIsRefused() throws {
        let root = try sandbox()
        let inner = root.appending(path: "inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let escape = inner.path + "/../../escaped.txt"
        #expect(!FolderScope(folders: [inner]).allows(escape))
    }

    @Test func aSymlinkPointingOutIsRefused() throws {
        // The one that a simple prefix check gets wrong.
        let root = try sandbox()
        let outside = try sandbox()
        let target = outside.appending(path: "target.txt")
        try "outside".write(to: target, atomically: true, encoding: .utf8)
        let link = root.appending(path: "link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(!FolderScope(folders: [root]).allows(link.path))
    }

    @Test func aFileThatDoesNotExistYetIsJudgedByItsParent() throws {
        let root = try sandbox()
        #expect(FolderScope(folders: [root]).allows(root.appending(path: "new.txt").path))
        #expect(FolderScope(folders: [root]).allows(root.appending(path: "a/b/new.txt").path))
        let outside = try sandbox()
        #expect(!FolderScope(folders: [root]).allows(outside.appending(path: "new.txt").path))
    }

    @Test func nonsenseIsRefusedRatherThanAllowed() throws {
        let root = try sandbox()
        let scope = FolderScope(folders: [root])
        #expect(!scope.allows(""))
        #expect(!scope.allows("relative/path.txt"), "a path with no root is not a path")
        #expect(!scope.allows("/"))
    }

    @Test func anAgentWithNoFoldersMayReachNothing() {
        #expect(!FolderScope(folders: []).allows("/tmp/anything.txt"))
    }

    @Test func aSecondFolderIsReachableToo() throws {
        let first = try sandbox()
        let second = try sandbox()
        let file = second.appending(path: "notes.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        #expect(FolderScope(folders: [first, second]).allows(file.path))
    }

    @Test func theFolderItselfIsInside() throws {
        let root = try sandbox()
        #expect(FolderScope(folders: [root]).allows(root.path))
    }

    @Test func theRefusalSaysWhereItCouldHaveWritten() throws {
        let root = try sandbox()
        let refusal = FolderScope(folders: [root]).refusal(for: "/etc/passwd")
        #expect(refusal.contains(root.path))
    }
}
