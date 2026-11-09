import Foundation
import Testing
@testable import AgentsKitCore

/// A secret's use waiting on a person (#4017): its Needs you row says who wants which secret
/// and where its value goes, never the value; its answers go as `requests/answer`'s; and its
/// banner's need decodes and names it.
@Suite("A secret's use in Needs you")
struct SecretUseRequestTests {
    private func request(_ detail: String, source: String = "secretUse") throws -> NeedRequest {
        NeedRequest(id: UUID(), kind: .approve, source: source, title: "Fill GITLAB_PASSWORD on gitlab.com",
                    detail: try JSONValue.parse(Data(detail.utf8)), folder: URL(filePath: "/tmp/work/api"),
                    askedBy: UUID(), askedAt: Date(timeIntervalSince1970: 10))
    }

    @Test func theRowSaysWhoWantsWhichSecretAndWhere() throws {
        let fill = try request(#"{"secretUse":{"name":"GITLAB_PASSWORD","use":"fill","place":"gitlab.com"}}"#)
        #expect(fill.title(asker: "Sign up") == "Wants to use GITLAB_PASSWORD")
        #expect(fill.line(asker: "Sign up") == "Sign up · Fill on gitlab.com")
        #expect(fill.secretUse?.actions == [.once, .session, .always, .deny])
        let ci = try request(#"{"secretUse":{"name":"TOKEN","use":"ci","place":"alexec/agents","sessionOnly":true}}"#)
        #expect(ci.line(asker: nil) == "CI secret in alexec/agents")
        #expect(ci.secretUse?.actions == [.once, .session, .deny])
        let mcp = try request(#"{"secretUse":{"name":"NOTES_TOKEN","use":"mcp","place":"notes"}}"#)
        #expect(mcp.line(asker: nil) == "MCP server notes")
        #expect(NeedRequest.Action.allCases.map(\.word) == ["Allow Once", "Allow for This Session", "Allow Always", "Deny"])
    }

    @Test func anotherRequestKeepsItsOwnTitle() throws {
        let question = try request("{}", source: "question")
        #expect(question.secretUse == nil)
        #expect(question.title(asker: "Sign up") == "Fill GITLAB_PASSWORD on gitlab.com")
    }

    @Test func theAnswerIsTheWiresShape() throws {
        let id = UUID()
        let sent = try JSONValue.encoding(DaemonAPI.RequestsAnswer(id: id, secretUse: .always))
        #expect(sent["answer"]?["secretUse"]?["action"]?.stringValue == "always")
        #expect(sent["id"]?.stringValue == id.uuidString)
    }

    @Test func theBannersNeedNamesTheRequest() throws {
        let id = UUID()
        let decoded = try JSONDecoder().decode(NeedID.self, from: Data(#"{"request":"\#(id.uuidString)"}"#.utf8))
        #expect(decoded == .request(id))
        #expect(decoded.token == "request:\(id.uuidString)")
        #expect(try JSONDecoder().decode(Need.Kind.self, from: Data(#""request""#.utf8)) == .request)
    }
}
