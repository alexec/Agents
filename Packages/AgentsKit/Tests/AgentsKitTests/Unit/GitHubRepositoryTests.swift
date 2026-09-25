import Foundation
import Testing
@testable import AgentsKitCore

/// Which projects are on GitHub (038 FR-001): the host of `origin` contains `github`.
@Suite("A project's repository on GitHub")
struct GitHubRepositoryTests {
    private func repository(_ url: String) -> GitHubRepository? {
        GitRemote(url).flatMap(GitHubRepository.init(remote:))
    }

    @Test func githubDotComInEitherSpelling() {
        for url in ["https://github.com/alexec/agents.git", "git@github.com:alexec/agents.git",
                    "ssh://git@github.com/alexec/agents", "https://github.com/alexec/agents/"] {
            let found = repository(url)
            #expect(found == GitHubRepository(host: "github.com", owner: "alexec", name: "agents"), "\(url)")
        }
    }

    @Test func anEnterpriseHostCounts() {
        let found = repository("https://github.example.com/team/tool.git")
        #expect(found?.host == "github.example.com")
        #expect(found?.fullName == "team/tool")
        #expect(found?.webURL.absoluteString == "https://github.example.com/team/tool")
    }

    @Test func theHostIsLowercased() {
        #expect(repository("https://GitHub.com/alexec/agents")?.host == "github.com")
    }

    @Test func otherForgesAreNot() {
        #expect(repository("https://gitlab.com/alexec/agents.git") == nil)
        #expect(repository("git@bitbucket.org:alexec/agents.git") == nil)
    }

    @Test func aPathOfOneOrThreePartsIsNotARepository() {
        #expect(repository("https://github.com/agents") == nil)
        #expect(repository("https://github.com/org/group/agents") == nil)
    }
}
