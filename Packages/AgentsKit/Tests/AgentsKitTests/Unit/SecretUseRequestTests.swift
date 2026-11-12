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
        // #4163: an agent's read of an account with Ask before use, with a secret's answers.
        let account = try request(#"{"secretUse":{"name":"gitlab.com (a@example.com)","use":"account","place":"1a2b3c4d","call":"get"}}"#)
        #expect(account.title(asker: "Sign up") == "Wants to read gitlab.com (a@example.com)")
        #expect(account.line(asker: "Sign up") == "Sign up · Account: manage_accounts get")
        #expect(account.secretUse?.actions == [.once, .session, .always, .deny])
        #expect(NeedRequest.Action.allCases.map(\.word) == ["Approve", "Approve for This Session", "Always Approve", "Approve for 1 Hour", "Deny"])
    }

    /// #4179: a terminal's agents-secret has no session; its answers are once, for 1 hour and
    /// deny, and its grey line says the known gap.
    @Test func aTerminalsRowSaysTheGap() throws {
        let terminal = NeedRequest(id: UUID(), kind: .approve, source: "secretUse", title: "Print PLAIN_KEY in a terminal (zsh)",
                                   detail: try JSONValue.parse(Data(#"{"secretUse":{"name":"PLAIN_KEY","use":"terminal","place":"zsh"}}"#.utf8)),
                                   folder: URL(filePath: "/Users/someone/"), askedBy: nil, askedAt: Date(timeIntervalSince1970: 10))
        #expect(terminal.isTerminal)
        #expect(terminal.title(asker: nil) == "Wants to use PLAIN_KEY")
        #expect(terminal.line(asker: nil) == "Terminal: zsh · Agents cannot tell a terminal from an agent outside its session.")
        #expect(terminal.secretUse?.actions == [.once, .hour, .deny])
        #expect(try request(#"{"secretUse":{"name":"T","use":"fill","place":"a.com"}}"#).isTerminal == false)
        let sent = try JSONValue.encoding(DaemonAPI.RequestsAnswer(id: terminal.id, secretUse: .hour))
        #expect(sent["answer"]?["secretUse"]?["action"]?.stringValue == "hour")
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

    /// #4149: a Linux machine's request says needsSignature, and an answer that allows the use
    /// goes signed for that machine, over the params Go's secretrelease.Approval reads.
    @Test func anAllowOnALinuxMachineGoesSigned() throws {
        let linux = try request(#"{"secretUse":{"name":"TOKEN","use":"ci","place":"alexec/agents","needsSignature":true}}"#)
        let use = try #require(linux.secretUse)
        #expect(use.signs(.once) && use.signs(.always) && !use.signs(.deny))
        #expect(try request(#"{"secretUse":{"name":"TOKEN","use":"ci","place":"a/b"}}"#).secretUse?.signs(.once) == false)

        let device = LockSigningKey.ephemeral()
        let approval = try LockChannel.secretUseApproval(device, to: "h-1", request: linux.id, use: use, action: .session)
        #expect(approval.method == "secrets/approveUse")
        let params = try JSONValue.parse(Data(approval.params.utf8))
        #expect(params["request"]?.stringValue == linux.id.uuidString)
        #expect(params["name"]?.stringValue == "TOKEN" && params["use"]?.stringValue == "ci")
        #expect(params["place"]?.stringValue == "alexec/agents" && params["action"]?.stringValue == "session")
        #expect(approval.lock.to == "h-1" && approval.lock.key == device.publicKey)
        let signed = LockChannel.requestData(to: "h-1", at: approval.lock.at, method: approval.method, params: approval.params)
        #expect(LockChannel.verify(device.publicKey, signed, approval.lock.sig))

        let sent = try JSONValue.encoding(DaemonAPI.RequestsAnswer(id: linux.id, secretUse: .session, approval: approval))
        #expect(sent["answer"]?["secretUse"]?["approval"]?["params"]?.stringValue == approval.params)
    }

        @Test func theBannersNeedNamesTheRequest() throws {
        let id = UUID()
        let decoded = try JSONDecoder().decode(NeedID.self, from: Data(#"{"request":"\#(id.uuidString)"}"#.utf8))
        #expect(decoded == .request(id))
        #expect(decoded.token == "request:\(id.uuidString)")
        #expect(try JSONDecoder().decode(Need.Kind.self, from: Data(#""request""#.utf8)) == .request)
    }
}
