import Foundation
@testable import AgentsKit
@testable import AgentsKitCore

/// A stand-in for the person's `gh` (038): a shell script that answers from a recorded
/// response, fails the way `gh` fails, and writes down what it was asked.
///
/// A script rather than a Swift fake, so that `GitHubCLI` runs a real process the
/// same way it runs the real one, and what is tested includes the arguments it passes.
struct FakeGitHub {
    enum Mode: String {
        /// Answer GraphQL with `response.json`, and anything else with `reply.json`.
        case answers
        /// Not signed in: every call fails, and so does `auth status`.
        case signedOut
        /// Signed in, and GitHub cannot be reached.
        case offline
    }

    let folder: URL

    var script: URL { folder.appending(path: "gh") }
    var calls: URL { folder.appending(path: "calls.log") }
    var cli: GitHubCLI {
        let script = script
        return GitHubCLI(executable: { script })
    }

    init() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FakeGitHub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dir = folder.path(percentEncoded: false)
        let text = """
            #!/bin/sh
            dir='\(dir)'
            printf '%s' "$*" | tr '\\n' ' ' >> "$dir/calls.log"; echo >> "$dir/calls.log"
            mode=$(cat "$dir/mode" 2>/dev/null || echo answers)
            if [ "$1" = "auth" ]; then
              [ "$mode" = "signedOut" ] && { echo "You are not logged into any accounts" >&2; exit 1; }
              exit 0
            fi
            case "$mode" in
              signedOut) echo "gh: To get started with GitHub CLI, please run:  gh auth login" >&2; exit 4 ;;
              offline) echo "error connecting to api.github.com" >&2; exit 1 ;;
            esac
            if [ "$2" = "graphql" ]; then cat "$dir/response.json"; else cat "$dir/reply.json" 2>/dev/null || echo '{}'; fi
            exit 0
            """
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try set(.answers)
    }

    func set(_ mode: Mode) throws {
        try mode.rawValue.write(to: folder.appending(path: "mode"), atomically: true, encoding: .utf8)
    }

    /// Answer with one of the recorded fixtures under `Fixtures/GitHub`.
    func answer(with fixture: String) throws {
        let source = URL(filePath: #filePath)
            .deletingLastPathComponent()      // Support
            .deletingLastPathComponent()      // AgentsKitTests
            .appending(path: "Fixtures/GitHub/\(fixture).json")
        try Data(contentsOf: source).write(to: folder.appending(path: "response.json"))
    }

    /// Answer with a response written in the test.
    func answer(_ json: String) throws {
        try json.write(to: folder.appending(path: "response.json"), atomically: true, encoding: .utf8)
    }

    /// Answer every call that is not GraphQL — a REST call — with this (042: whether a
    /// pull request that left the open list was merged).
    func reply(_ json: String) throws {
        try json.write(to: folder.appending(path: "reply.json"), atomically: true, encoding: .utf8)
    }

    /// Every call so far, one line of arguments each.
    func calledWith() -> [String] {
        ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}
