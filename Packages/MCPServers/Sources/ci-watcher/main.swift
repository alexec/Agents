// The CI watcher (#383, #700), one static binary on stdio:
//
//   ci-watcher                        gh as the signed-in person
//   CI_WATCHER_FAKE=<file> ci-watcher reads and writes <file> instead
import CIWatcher
import Foundation
import MCPServerKit

if CommandLine.arguments.dropFirst().contains(where: { $0 == "--version" || $0 == "-v" }) {
    print("ci-watcher \(CIWatcher.version)")
    exit(0)
}

let fake = ProcessInfo.processInfo.environment["CI_WATCHER_FAKE"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
if let fake, !FileManager.default.fileExists(atPath: fake.path) {
    log("ci-watcher: no such file \(fake.path)")
    exit(2)
}
log("ci-watcher \(CIWatcher.version) on stdio\(fake.map { " (fake: \($0.path))" } ?? "")")
let server = fake.map { CIWatcher.server(FakeGitHub(file: $0)) } ?? CIWatcher.server(RealGitHub())
await StdioTransport.serve(server, name: "ci-watcher")
