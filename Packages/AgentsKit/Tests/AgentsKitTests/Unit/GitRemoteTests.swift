import Foundation
import Testing
@testable import AgentsKitCore

/// What a pasted URL is taken to be (027): which spellings are cloned, what folder each
/// becomes, and which spellings are the same repository.
@Suite("Git remote")
struct GitRemoteTests {
    @Test(arguments: [
        ("https://github.com/octocat/Hello-World.git", "github.com", "octocat/Hello-World.git", "Hello-World"),
        ("https://github.com/octocat/Hello-World", "github.com", "octocat/Hello-World", "Hello-World"),
        ("https://github.com/octocat/Hello-World/", "github.com", "octocat/Hello-World", "Hello-World"),
        ("  https://GitHub.com/octocat/Hello-World.git\n", "github.com", "octocat/Hello-World.git", "Hello-World"),
        ("git@github.com:octocat/Hello-World.git", "github.com", "octocat/Hello-World.git", "Hello-World"),
        ("github.com:octocat/Hello-World", "github.com", "octocat/Hello-World", "Hello-World"),
        ("ssh://git@github.com/octocat/Hello-World.git", "github.com", "octocat/Hello-World.git", "Hello-World"),
        ("ssh://git@git.example.com:2222/team/sub/api.git", "git.example.com", "team/sub/api.git", "api"),
        ("https://user@gitlab.com/group/project.git", "gitlab.com", "group/project.git", "project"),
    ])
    func acceptedSpellings(text: String, host: String, path: String, folder: String) throws {
        let remote = try #require(GitRemote(text))
        #expect(remote.host == host)
        #expect(remote.path == path)
        #expect(remote.folderName == folder)
        #expect(remote.url == text.trimmingCharacters(in: .whitespacesAndNewlines),
                "git is handed what was pasted, trimmed, and nothing else")
    }

    @Test(arguments: [
        "",
        "   ",
        "hello world",
        "/Users/alex/Code/api",
        "~/Code/api",
        "./a:b",
        "file:///Users/alex/api.git",
        "http://github.com/octocat/Hello-World.git",
        "git://github.com/octocat/Hello-World.git",
        "https://github.com",
        "https://github.com/",
        "git@github.com:",
        "-uhttps://evil",
        "--upload-pack=touch /tmp/x",
        "https://github.com/octocat/.git",
        "https://github.com/octocat/..",
        "https://github.com/a b/c",
    ])
    func refusedSpellings(text: String) {
        #expect(GitRemote(text) == nil, "\(text) must not be cloned")
    }

    @Test func httpsAndSSHSpellingsAreTheSameRepository() throws {
        let spellings = [
            "https://github.com/octocat/Hello-World.git",
            "https://github.com/octocat/hello-world",
            "https://GITHUB.com/octocat/Hello-World/",
            "git@github.com:octocat/Hello-World.git",
            "ssh://git@github.com/octocat/Hello-World",
        ]
        let identities = Set(try spellings.map { try #require(GitRemote($0)).identity })
        #expect(identities.count == 1)
    }

    @Test func differentRepositoriesAreNot() throws {
        let one = try #require(GitRemote("https://github.com/octocat/Hello-World"))
        let fork = try #require(GitRemote("https://github.com/someone/Hello-World"))
        let elsewhere = try #require(GitRemote("https://gitlab.com/octocat/Hello-World"))
        #expect(one.identity != fork.identity)
        #expect(one.identity != elsewhere.identity)
        #expect(one.folderName == fork.folderName, "which is why a fork is refused as in the way")
    }
}
