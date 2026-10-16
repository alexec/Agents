import AgentsKitCore
import Foundation
import Testing
@testable import AgentsKit

/// What git and `agentsd git-credential` say to each other (#1122), and how a host's git is
/// given the helper.
@Suite("Lent git access, as git sees it", .serialized)
struct GitLendingUnitTests {
    @Test func onlyHttpsWithAServerIsAsked() {
        let asked = DaemonAPI.GitCredentialRequest(gitAttributes: "protocol=https\nhost=github.com\npath=alexec/agents.git\n\n")
        #expect(asked == DaemonAPI.GitCredentialRequest(protocol: "https", host: "github.com"))
        #expect(DaemonAPI.GitCredentialRequest(gitAttributes: "protocol=http\nhost=github.com\n") == nil)
        #expect(DaemonAPI.GitCredentialRequest(gitAttributes: "protocol=https\n") == nil)
        #expect(DaemonAPI.GitCredentialRequest(gitAttributes: "protocol=https\nhost=a b\n") == nil)
        #expect(DaemonAPI.GitCredentialRequest(gitAttributes: "protocol=https\nhost=git.example.com:8443\n")?.host
            == "git.example.com:8443")
    }

    @Test func aCredentialNeverPrints() throws {
        let secret = "gho_" + "SECRETSECRETSECRET"
        let credential = try #require(DaemonAPI.GitCredential(gitAttributes: "protocol=https\nhost=github.com\nusername=alex\npassword=\(secret)\n"))
        #expect(credential.username == "alex")
        #expect(credential.gitAttributes == "username=alex\npassword=\(secret)\n")
        #expect(!"\(credential)".contains(secret))
        #expect(!String(reflecting: credential).contains(secret))
        var dumped = ""
        dump(credential, to: &dumped)
        #expect(!dumped.contains(secret))
        #expect(DaemonAPI.GitCredential(gitAttributes: "username=alex\n") == nil)
    }

    /// Git runs the helper for every process of the account, so a stranger on the socket may
    /// ask for a lent credential, and for nothing more than before.
    @Test func aStrangerMayAskForALentCredentialOnly() {
        #expect(ConnectionRole.stranger.allows(DaemonAPI.Method.gitCredential))
        #expect(!ConnectionRole.stranger.allows(DaemonAPI.Method.gitFill))
        #expect(!ConnectionRole.stranger.allows(DaemonAPI.Method.agentsList))
    }

    @Test func theHelperIsLaidOverGitsConfigAfterAnyThere() {
        defer { GitLending.disable() }
        #expect(GitLending.applied(to: ["A": "1"]) == ["A": "1"])
        GitLending.enable(executable: URL(filePath: "/home/agents/.agents-server/bin/agentsd"),
                          socket: URL(filePath: "/home/agents/.agents-server/daemon.sock"))
        let environment = GitLending.applied(to: ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "x.y", "GIT_CONFIG_VALUE_0": "z"])
        #expect(environment["GIT_CONFIG_COUNT"] == "3")
        #expect(environment["GIT_CONFIG_KEY_0"] == "x.y")
        #expect(environment["GIT_CONFIG_KEY_1"] == "credential.helper")
        #expect(environment["GIT_CONFIG_VALUE_1"] == "")
        #expect(environment["GIT_CONFIG_VALUE_2"]
            == "!'/home/agents/.agents-server/bin/agentsd' git-credential '/home/agents/.agents-server/daemon.sock'")
        #expect(GitLending.quoted("it's") == "'it'\\''s'")
    }
}
