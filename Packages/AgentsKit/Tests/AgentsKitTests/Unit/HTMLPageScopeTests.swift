import Foundation
import Testing
@testable import AgentsKitCore

@Suite("What an HTML page in the files pane may reach (#67)")
struct HTMLPageScopeTests {
    let scope = HTMLPageScope(root: "/work/project")
    let stamp = FileStamp(size: 1, modifiedAt: Date(timeIntervalSince1970: 0))

    private func url(_ string: String) -> URL { URL(string: string)! }

    // MARK: Scope

    @Test func theAgentsFolderIsTheScopeForAFileInIt() {
        let scope = HTMLPageScope(file: URL(filePath: "/work/project/out/report.html"),
                                  agentFolder: URL(filePath: "/work/project"))
        #expect(scope.root == "/work/project")
    }

    @Test func aFileOutsideTheAgentsFolderReachesOnlyItsOwnFolder() {
        let scope = HTMLPageScope(file: URL(filePath: "/elsewhere/docs/index.html"),
                                  agentFolder: URL(filePath: "/work/project"))
        #expect(scope.root == "/elsewhere/docs")
    }

    @Test func aSiblingFolderWithTheSamePrefixIsNotInside() {
        let scope = HTMLPageScope(file: URL(filePath: "/work/project-old/report.html"),
                                  agentFolder: URL(filePath: "/work/project"))
        #expect(scope.root == "/work/project-old")
    }

    @Test func thePageIsPutAtItsPlaceUnderTheFolder() {
        #expect(scope.address(of: "/work/project/out/report.html")?.absoluteString
                == "agents-page://folder/out/report.html")
        #expect(scope.address(of: "/work/project/a b.html")?.absoluteString
                == "agents-page://folder/a%20b.html")
        #expect(scope.address(of: "/work/other/report.html") == nil)
    }

    @Test func aRelativeAssetResolvesBesideThePage() throws {
        let page = try #require(scope.address(of: "/work/project/out/report.html"))
        let css = try #require(URL(string: "style.css", relativeTo: page)?.absoluteURL)
        #expect(scope.path(for: css) == .success("/work/project/out/style.css"))
        let image = try #require(URL(string: "img/chart%20one.png", relativeTo: page)?.absoluteURL)
        #expect(scope.path(for: image) == .success("/work/project/out/img/chart one.png"))
    }

    // MARK: Refusals

    @Test(arguments: [
        "agents-page://folder/../secret.txt",
        "agents-page://folder/out/../../etc/passwd",
        "agents-page://folder/%2E%2E/secret.txt",
        "agents-page://folder/%2e%2e%2fsecret.txt",
        "agents-page://folder/out/..%2F..%2Fetc%2Fpasswd",
    ])
    func aPathThatClimbsIsRefused(address: String) {
        #expect(scope.path(for: url(address)) == .failure(.climbs))
    }

    @Test(arguments: [
        "file:///work/project/style.css",
        "https://example.com/style.css",
        "agents-page://elsewhere/style.css",
        "agents://folder/style.css",
    ])
    func anotherSchemeOrHostIsRefused(address: String) {
        #expect(scope.path(for: url(address)) == .failure(.notThisPage))
    }

    @Test func nothingNamedIsRefused() {
        #expect(scope.path(for: url("agents-page://folder/")) == .failure(.malformed))
        #expect(scope.path(for: url("agents-page://folder/%00.css")) == .failure(.malformed))
    }

    @Test func everyPathAnsweredIsInsideTheRoot() {
        for address in ["agents-page://folder/a.css", "agents-page://folder/./b/./c.png",
                        "agents-page://folder//d.js", "agents-page://folder/e%2Ff.css"] {
            guard case .success(let path) = scope.path(for: url(address)) else {
                Issue.record("refused \(address)")
                continue
            }
            #expect(path.hasPrefix("/work/project/"))
            #expect(!path.contains("/./") && !path.contains("//"))
        }
    }

    // MARK: Answers

    @Test func aStylesheetIsReadFromTheHostAndServedAsCSS() async {
        let asked = Asked()
        let answer = await scope.answer(url("agents-page://folder/out/style.css")) { path in
            await asked.add(path)
            return .text("h1 { color: red }", isTruncated: false, size: 17, stamp: stamp)
        }
        #expect(answer == .file(Data("h1 { color: red }".utf8), mimeType: "text/css", isText: true))
        #expect(await asked.paths == ["/work/project/out/style.css"])
    }

    @Test func aPictureIsServedWhole() async {
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let answer = await scope.answer(url("agents-page://folder/chart.png")) { _ in
            .image(bytes, describedAs: "PNG image", stamp: stamp)
        }
        #expect(answer == .file(bytes, mimeType: "image/png", isText: false))
    }

    @Test func aRefusedPathIsNeverAskedOfTheHost() async {
        let asked = Asked()
        let answer = await scope.answer(url("agents-page://folder/%2E%2E/secret")) { path in
            await asked.add(path)
            return .text("secret", isTruncated: false, size: 6, stamp: stamp)
        }
        #expect(answer == .refused(status: 403, reason: "A path that climbs out of the folder is not followed."))
        #expect(await asked.paths.isEmpty)
    }

    @Test func aCutTextFileIsRefusedRatherThanSentHalf() async {
        let answer = await scope.answer(url("agents-page://folder/big.js")) { _ in
            .text("var a", isTruncated: true, size: 500_000, stamp: stamp)
        }
        guard case .refused(let status, _) = answer else {
            Issue.record("served a cut file")
            return
        }
        #expect(status == 413)
    }

    @Test func aFileTheHostWillNotCarryIsRefused() async {
        let answer = await scope.answer(url("agents-page://folder/font.woff2")) { _ in
            .other(describedAs: "Font", size: 20_000, stamp: stamp)
        }
        guard case .refused(let status, _) = answer else {
            Issue.record("served a file the host did not carry")
            return
        }
        #expect(status == 415)
    }

    @Test func theHostsRefusalIsPassedOn() async {
        let answer = await scope.answer(url("agents-page://folder/link-out.css")) { _ in
            throw JSONRPCError(code: JSONRPCError.invalidParams, message: "That is outside the agent's folders.")
        }
        #expect(answer == .refused(status: 403, reason: "That is outside the agent's folders."))
        let gone = await scope.answer(url("agents-page://folder/missing.css")) { _ in
            throw JSONRPCError(code: DaemonAPI.Failure.fileGone, message: "missing.css is gone.")
        }
        #expect(gone == .refused(status: 404, reason: "missing.css is gone."))
    }

    // MARK: Links

    @Test func linksNeverLoadInTheFileView() {
        let page = url("agents-page://folder/out/report.html")
        #expect(scope.decide(link: url("agents-page://folder/out/report.html#results"), on: page) == .stay)
        #expect(scope.decide(link: url("agents-page://folder/out/other.html"), on: page)
                == .openFile("/work/project/out/other.html"))
        #expect(scope.decide(link: url("https://example.com/docs"), on: page)
                == .openOutside(url("https://example.com/docs")))
        #expect(scope.decide(link: url("mailto:a@b.com"), on: page) == .openOutside(url("mailto:a@b.com")))
        #expect(scope.decide(link: url("javascript:alert(1)"), on: page) == .ignore)
        #expect(scope.decide(link: url("data:text/html,<p>hi</p>"), on: page) == .ignore)
        #expect(scope.decide(link: url("file:///etc/passwd"), on: page) == .ignore)
        #expect(scope.decide(link: url("agents-page://folder/%2E%2E/x.html"), on: page) == .ignore)
    }

    @Test func onlyHTMLIsAPage() {
        #expect(HTMLPageScope.isHTML(URL(filePath: "/a/report.html")))
        #expect(HTMLPageScope.isHTML(URL(filePath: "/a/INDEX.HTM")))
        #expect(!HTMLPageScope.isHTML(URL(filePath: "/a/notes.md")))
        #expect(!HTMLPageScope.isHTML(URL(filePath: "/a/page.xhtml")))
    }

    @Test func theRuleListBlocksEverythingButThePagesScheme() throws {
        let rules = try #require(try JSONSerialization.jsonObject(
            with: Data(HTMLPageScope.contentRules.utf8)) as? [[String: [String: String]]])
        #expect(rules.first?["action"]?["type"] == "block")
        #expect(rules.first?["trigger"]?["url-filter"] == ".*")
        // Everything after the block lets through only what is already on this Mac or in
        // the page: its own scheme, and inlined `data:` and `blob:`.
        #expect(rules.dropFirst().allSatisfy { $0["action"]?["type"] == "ignore-previous-rules" })
        #expect(rules.dropFirst().compactMap { $0["trigger"]?["url-filter"] }
                == ["^agents-page:", "^data:", "^blob:"])
    }
}

private actor Asked {
    var paths: [String] = []
    func add(_ path: String) { paths.append(path) }
}
