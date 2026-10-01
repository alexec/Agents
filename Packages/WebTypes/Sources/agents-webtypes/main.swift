import Foundation
import WebTypesKit

// agents-webtypes [--root <repo>] [--check]
//
// Writes Web/src/protocol/generated.ts from AgentsKitCore's source (071, research R6). With
// --check it writes nothing, and exits 1 if the file on disk is not what it would write.

var arguments = CommandLine.arguments.dropFirst()
var root = URL(filePath: FileManager.default.currentDirectoryPath)
var check = false
while let argument = arguments.popFirst() {
    switch argument {
    case "--root":
        guard let path = arguments.popFirst() else { fail("--root needs a folder") }
        root = URL(filePath: path)
    case "--check": check = true
    default: fail("usage: agents-webtypes [--root <repo>] [--check]")
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("agents-webtypes: \(message)\n".utf8))
    exit(1)
}

do {
    let generator = Generator(root: root)
    let made = try generator.generate()
    let file = root.appending(path: Generator.output)
    let current = try? String(contentsOf: file, encoding: .utf8)
    if check {
        guard current == made else { fail(Freshness.message(current: current, made: made)) }
    } else if current != made {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try made.write(to: file, atomically: true, encoding: .utf8)
        print("agents-webtypes: wrote \(Generator.output)")
    }
} catch {
    fail(String(describing: error))
}
