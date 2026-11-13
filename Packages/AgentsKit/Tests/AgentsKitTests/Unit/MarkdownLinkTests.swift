import Foundation
import Testing
@testable import AgentsKitCore

@Suite("Where a link on a Markdown page goes")
struct MarkdownLinkTests {
    let page = URL(filePath: "/work/folder/docs/guide/index.md")

    /// The link as the page's own reader makes it: Foundation's Markdown, as `MarkdownBlock` reads it.
    private func link(_ target: String) throws -> URL {
        let text = try AttributedString(markdown: "[here](\(target))", options: .init(interpretedSyntax: .full))
        return try #require(text.runs.compactMap(\.link).first)
    }

    private func target(_ written: String) throws -> MarkdownLink {
        MarkdownLink.target(of: try link(written), onPage: page)
    }

    @Test func aLinkBesideThePageIsTheFileBesideIt() throws {
        #expect(try target("other.md") == .file(URL(filePath: "/work/folder/docs/guide/other.md")))
        #expect(try target("./other.md") == .file(URL(filePath: "/work/folder/docs/guide/other.md")))
    }

    @Test func aLinkThatClimbsIsReadFromThePagesFolder() throws {
        #expect(try target("../reference/api.md") == .file(URL(filePath: "/work/folder/docs/reference/api.md")))
    }

    @Test func aFragmentIsDropped() throws {
        #expect(try target("other.md#setup") == .file(URL(filePath: "/work/folder/docs/guide/other.md")))
    }

    @Test func spacesInTheNameAreKept() throws {
        #expect(try target("my%20notes.md") == .file(URL(filePath: "/work/folder/docs/guide/my notes.md")))
    }

    @Test func anAbsolutePathIsThatPath() throws {
        #expect(try target("/etc/hosts") == .file(URL(filePath: "/etc/hosts")))
        #expect(try target("file:///work/a.md#top") == .file(URL(filePath: "/work/a.md")))
    }

    @Test func onlyAFragmentStaysOnThePage() throws {
        #expect(try target("#setup") == .samePage)
    }

    @Test func aLinkWithASchemeIsTheAppsToOpen() throws {
        #expect(try target("https://example.com/a.md") == .other(URL(string: "https://example.com/a.md")!))
        #expect(try target("mailto:a@example.com") == .other(URL(string: "mailto:a@example.com")!))
    }
}
