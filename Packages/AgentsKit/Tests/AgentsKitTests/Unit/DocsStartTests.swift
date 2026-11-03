import Foundation
import Testing
@testable import AgentsKitCore

/// Start Agent on a doc and the Docs section on Work's pages (#3322), as Web/test/docs.test.mjs has
/// them on the web page.
@Suite("Docs start and links")
struct DocsStartTests {
    typealias Doc = DaemonAPI.Doc

    static func doc(_ path: String, title: String = "A doc") -> Doc {
        Doc(ref: "github:alexec/agents/doc/\(path)", title: title, source: "/a", folder: "/a", path: path)
    }

    @Test("Build this names the doc in its prompt and labels the session doc:<short form>")
    func buildPrompt() {
        let spec = Self.doc("specs/3319-docs/spec.md")
        #expect(DocsList.Start.build.prompt(spec.ref).contains(spec.ref))
        #expect(DocsList.Start.build.prompt(spec.ref).contains("docs_read"))
        #expect(DocsList.Start.build.labels(spec) == ["doc:3319-docs/spec.md"])
        #expect(DocsList.Start.review.labels(spec).isEmpty)
        #expect(DocsList.Start.ask.labels(spec).isEmpty)
        #expect(DocsList.Start.allCases.map(\.title) == ["Build this", "Review this", "Ask about this"])
    }

    @Test("The doc: label fits a session label: whole path parts, a file name's end, a title's start")
    func label() throws {
        #expect(DocsList.label(Self.doc("README.md")) == "doc:README.md")
        #expect(DocsList.label(Self.doc("docs/explanation/leases.md")) == "doc:leases.md")
        #expect(DocsList.label(Self.doc("specs/a-very-long-file-name-here.md")) == "doc:ng-file-name-here.md")
        let page = Doc(ref: "confluence:acme/1", title: "Payments: requirements and more", source: "mcp:confluence")
        #expect(DocsList.label(page) == "doc:Payments: requiremen")
        for d in [Self.doc("specs/3319-docs/spec.md"), Self.doc("specs/a-very-long-file-name-here.md"), page] {
            #expect(try SessionLabelPolicy.cleaned(DocsList.label(d)) == DocsList.label(d))
        }
    }

    @Test("An item's body names docs by ref, by address and by a specs/ or docs/ path of its repo")
    func linked() {
        let body = """
        Spec: `specs/3319-docs/spec.md`, "A doc's page". See also docs/explanation/leases.md.
        The page: #/docs/github%3Aalexec%2Fagents%2Fdoc%2FREADME.md and agents://docs/confluence:acme.atlassian.net/123.
        Raw: github:alexec/agents/doc/specs/3265-work-plans/spec.md, notion:1f2e.
        Not these: https://github.com/alexec/Agents/blob/main/specs/0001/spec.md, src/docs/x.md, specs/3319-docs/spec.md again.
        """
        #expect(DocsList.linkedRefs(body: body, itemRef: "github:alexec/agents#3322") == [
            "github:alexec/agents/doc/specs/3319-docs/spec.md",
            "github:alexec/agents/doc/docs/explanation/leases.md",
            "github:alexec/agents/doc/README.md",
            "confluence:acme.atlassian.net/123",
            "github:alexec/agents/doc/specs/3265-work-plans/spec.md",
            "notion:1f2e",
        ])
        // An item of no repo (a Linear issue) finds no paths, only refs.
        #expect(DocsList.linkedRefs(body: "specs/a.md and notion:9", itemRef: "linear:ENG-4") == ["notion:9"])
        #expect(DocsList.repoPrefix("gitlab:acme/web!12") == "gitlab:acme/web/doc/")
    }

    @Test("A title is searched by its longest uncommon words, and the docs most of them find come first")
    func related() {
        #expect(DocsList.searchWords("Docs 3: Start Agent on a doc, and a Docs section on Work's issue and PR pages")
            == ["section", "start", "agent", "issue"])
        let a = Self.doc("a.md"), b = Self.doc("b.md"), c = Self.doc("c.md"), linked = Self.doc("l.md")
        func r(_ d: Doc, _ n: Int) -> DaemonAPI.DocsSearchResult {
            .init(doc: d, matches: Array(repeating: .init(line: 1, snippet: "x"), count: n))
        }
        let got = DocsList.related([[r(a, 1), r(linked, 9)], [r(b, 5), r(a, 1)], [r(c, 1), r(b, 1)]],
                                   leaving: [linked.ref])
        #expect(got.map(\.ref) == [b.ref, a.ref, c.ref])
    }
}
