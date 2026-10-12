import Foundation
@testable import AgentsKit
@testable import AgentsKitCore

/// A stand-in for the person's `gh`: a shell script that answers every call with a
/// recorded reply, or the one recorded for its path, and writes down what it was asked.
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
            for last; do :; done
            key=$(printf '%s' "$last" | tr '/?=&' '____')
            if [ -f "$dir/replies/$key.json" ]; then cat "$dir/replies/$key.json"; exit 0; fi
            if [ -d "$dir/replies" ]; then echo 'HTTP 404: Not Found' >&2; exit 1; fi
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

    /// Answer a call for this API path (its query too) with this. Once any is set, a path
    /// with none fails as GitHub's 404 does.
    func reply(_ json: String, for path: String) throws {
        let replies = folder.appending(path: "replies")
        try FileManager.default.createDirectory(at: replies, withIntermediateDirectories: true)
        let key = path.map { "/?=&".contains($0) ? "_" : $0 }
        try json.write(to: replies.appending(path: String(key) + ".json"), atomically: true, encoding: .utf8)
    }

    /// Every call so far, one line of arguments each.
    func calledWith() -> [String] {
        ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}
