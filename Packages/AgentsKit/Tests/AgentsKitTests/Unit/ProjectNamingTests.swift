import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Names stay short until there is a reason not to, and then only the folders that
/// collide grow.
@Suite("What a project is called")
struct ProjectNamingTests {
    private func url(_ path: String) -> URL { URL(filePath: path) }

    @Test func oneFolderIsItsOwnName() {
        let api = url("/Users/alex/work/api")
        #expect(ProjectNaming.displayNames(for: [api])[api] == "api")
    }

    @Test func foldersThatDoNotCollideStayShort() {
        let api = url("/Users/alex/work/api")
        let web = url("/Users/alex/side/web")
        let names = ProjectNaming.displayNames(for: [api, web])
        #expect(names[api] == "api")
        #expect(names[web] == "web")
    }

    @Test func aCollisionGrowsOnlyTheFoldersThatCollide() {
        let work = url("/Users/alex/work/api")
        let side = url("/Users/alex/side/api")
        let docs = url("/Users/alex/work/docs")
        let names = ProjectNaming.displayNames(for: [work, side, docs])
        #expect(names[work] == "work/api")
        #expect(names[side] == "side/api")
        #expect(names[docs] == "docs")
    }

    @Test func aCollisionThatNeedsTwoComponents() {
        let one = url("/Users/alex/one/src/api")
        let two = url("/Users/alex/two/src/api")
        let names = ProjectNaming.displayNames(for: [one, two])
        #expect(names[one] == "one/src/api")
        #expect(names[two] == "two/src/api")
    }

    @Test func aFolderAtTheRoot() {
        let root = url("/")
        let names = ProjectNaming.displayNames(for: [root])
        #expect(names[root] == "/")
    }

    @Test func pathsDifferingOnlyInCaseAreTwoProjects() {
        let lower = url("/Users/alex/work/api")
        let upper = url("/Users/alex/work/API")
        let names = ProjectNaming.displayNames(for: [lower, upper])
        #expect(names[lower] == "api")
        #expect(names[upper] == "API")
    }

    @Test func aNestedFolderIsNamedForItself() {
        let api = url("/Users/alex/work/api")
        let docs = url("/Users/alex/work/api/docs")
        let names = ProjectNaming.displayNames(for: [api, docs])
        #expect(names[api] == "api")
        #expect(names[docs] == "docs")
    }

    @Test func everyNameIsUniqueWhateverTheSet() {
        let folders = [url("/a/x"), url("/b/x"), url("/c/x"), url("/a/y")]
        let names = ProjectNaming.displayNames(for: folders)
        #expect(Set(names.values).count == folders.count)
    }
}
