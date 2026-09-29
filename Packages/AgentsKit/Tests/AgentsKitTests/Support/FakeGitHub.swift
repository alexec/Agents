import Foundation
@testable import AgentsKit
@testable import AgentsKitCore

/// A stand-in for the person's `gh`: a shell script that answers every call with a
/// recorded reply and writes down what it was asked.
///
/// A script rather than a Swift fake, so that `GitHubCLI` runs a real process the
/// same way it runs the real one, and what is tested includes the arguments it passes.
struct FakeGitHub {
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
            cat "$dir/reply.json" 2>/dev/null || echo '{}'
            exit 0
            """
        try text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    /// Answer every call with this.
    func reply(_ json: String) throws {
        try json.write(to: folder.appending(path: "reply.json"), atomically: true, encoding: .utf8)
    }

    /// Every call so far, one line of arguments each.
    func calledWith() -> [String] {
        ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}
