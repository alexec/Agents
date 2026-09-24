import Foundation
import Testing
@testable import AgentsKit

/// Git's words for a failed clone, said so somebody who never opened a terminal can act
/// on them (027 FR-007). The stderr here is what git 2.4x prints for each case.
@Suite("Clone failure")
struct CloneFailureTests {
    private let remote = GitRemote("https://github.com/octocat/Hello-World.git")!

    @Test(arguments: [
        ("fatal: unable to access 'https://github.com/octocat/Hello-World.git/': Could not resolve host: github.com",
         "Could not reach github.com"),
        ("remote: Repository not found.\nfatal: repository 'https://github.com/octocat/Hello-World.git/' not found",
         "There is no repository at github.com/octocat/Hello-World.git"),
        ("fatal: '/tmp/nothing.git' does not appear to be a git repository\nfatal: Could not read from remote repository.",
         "There is no repository at github.com/octocat/Hello-World.git"),
        ("fatal: repository '/tmp/nothing.git' does not exist",
         "There is no repository at github.com/octocat/Hello-World.git"),
        ("fatal: could not read Username for 'https://github.com': terminal prompts disabled",
         "needs a sign-in this Mac does not have"),
        ("git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.",
         "did not accept this Mac's SSH key"),
        ("Host key verification failed.\nfatal: Could not read from remote repository.",
         "is not a known SSH host on this Mac"),
        ("xcrun: error: invalid active developer path (/Library/Developer/CommandLineTools), missing xcrun",
         "Git is not installed on this Mac"),
    ])
    func knownFailuresAreSaidPlainly(errors: String, says: String) {
        let message = CloneFailure.explain(errors, remote: remote)
        #expect(message.contains(says), "\(message)")
        #expect(!message.contains("fatal:"), "git's prefix is not for people")
    }

    @Test func anythingElseIsGitsLastFatalLine() {
        let errors = "Cloning into 'x'...\nfatal: early EOF\nfatal: fetch-pack: invalid index-pack output\n"
        #expect(CloneFailure.explain(errors, remote: remote)
                == "Could not clone github.com/octocat/Hello-World.git: fetch-pack: invalid index-pack output")
    }

    @Test func silenceStillSaysWhich() {
        #expect(CloneFailure.explain("", remote: remote) == "Could not clone github.com/octocat/Hello-World.git.")
    }
}
