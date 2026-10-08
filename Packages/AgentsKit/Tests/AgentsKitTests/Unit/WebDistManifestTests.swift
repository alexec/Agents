import Foundation
import Testing
@testable import AgentsKitCore

/// The built web remote is what its source builds (071, FR-035a, research R8).
///
/// `Web/build.mjs` writes `Web/dist/MANIFEST`: a hash of every source input and every built
/// file. This holds the tree to it with no Node, so changing `Web/src` without rebuilding, or
/// editing `Web/dist` by hand, fails in anyone's `swift test`. Web/dist is not checked in
/// (#473): Agents Host's build makes it, so with none built yet there is nothing to check.
@Suite("Web dist manifest", .enabled(if: FileManager.default.fileExists(atPath: webDistRepo.appending(path: "Web/dist/MANIFEST").path),
                                     "no Web/dist built here; scripts/web.sh build makes one"))
struct WebDistManifestTests {
    static let repo = webDistRepo

    /// The same inputs `Web/build.mjs` hashes. Keep the two in step.
    static let fixedInputs = ["index.html", "sandbox.html", "build.mjs", "tsconfig.json", "package.json", "package-lock.json", ".node-version"]
    static let inputFolders = ["src", "assets"]

    @Test func theBuiltWebRemoteMatchesItsSource() throws {
        #expect(try Self.problems(in: Self.repo) == [])
    }

    @Test func aSourceChangedWithoutARebuildIsCaught() throws {
        let copy = try Self.copyOfWeb()
        defer { try? FileManager.default.removeItem(at: copy) }
        try Data("// changed\n".utf8).append(to: copy.appending(path: "Web/src/main.tsx"))
        #expect(try Self.problems(in: copy) == ["Web/src/main.tsx changed since Web/dist was built; run scripts/web.sh build"])
    }

    @Test func aHandEditedBuildIsCaught() throws {
        let copy = try Self.copyOfWeb()
        defer { try? FileManager.default.removeItem(at: copy) }
        try Data("/* edited */".utf8).append(to: copy.appending(path: "Web/dist/app.js"))
        #expect(try Self.problems(in: copy) == ["Web/dist/app.js is not what the build wrote; run scripts/web.sh build"])
    }

    @Test func addedAndMissingFilesAreCaught() throws {
        let copy = try Self.copyOfWeb()
        defer { try? FileManager.default.removeItem(at: copy) }
        try Data("export {};\n".utf8).write(to: copy.appending(path: "Web/src/new.ts"))
        try FileManager.default.removeItem(at: copy.appending(path: "Web/dist/app.css"))
        try Data("x".utf8).write(to: copy.appending(path: "Web/dist/stray.js"))
        try Data().write(to: copy.appending(path: "Web/src/.DS_Store"))
        #expect(try Self.problems(in: copy) == [
            "Web/src/new.ts is new since Web/dist was built; run scripts/web.sh build",
            "Web/dist/app.css is missing; run scripts/web.sh build",
            "Web/dist/stray.js was not written by the build; run scripts/web.sh build",
        ])
    }

    // MARK: The check

    static func problems(in repo: URL) throws -> [String] {
        let web = repo.appending(path: "Web")
        let text = try String(contentsOf: web.appending(path: "dist/MANIFEST"), encoding: .utf8)
        var recordedInputs: [String: String] = [:], recordedOutputs: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            switch parts[0] {
            case "src": recordedInputs[parts[2]] = parts[1]
            case "out": recordedOutputs[parts[2]] = parts[1]
            default: break
            }
        }

        let inputs = fixedInputs.map { "Web/" + $0 }.filter { exists(repo, $0) }
            + inputFolders.flatMap { files(under: "Web/" + $0, in: repo) }
        let outputs = files(under: "Web/dist", in: repo).filter { $0 != "Web/dist/MANIFEST" }

        var problems: [String] = []
        for path in inputs.sorted() {
            guard let hash = recordedInputs[path] else {
                problems.append("\(path) is new since Web/dist was built; run scripts/web.sh build"); continue
            }
            if try sha256(repo, path) != hash {
                problems.append("\(path) changed since Web/dist was built; run scripts/web.sh build")
            }
        }
        for path in recordedInputs.keys.sorted() where !inputs.contains(path) {
            problems.append("\(path) is gone since Web/dist was built; run scripts/web.sh build")
        }
        for path in recordedOutputs.keys.sorted() where !outputs.contains(path) {
            problems.append("\(path) is missing; run scripts/web.sh build")
        }
        for path in outputs.sorted() {
            guard let hash = recordedOutputs[path] else {
                problems.append("\(path) was not written by the build; run scripts/web.sh build"); continue
            }
            if try sha256(repo, path) != hash {
                problems.append("\(path) is not what the build wrote; run scripts/web.sh build")
            }
        }
        return problems
    }

    private static func exists(_ repo: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: repo.appending(path: path).path)
    }

    /// Every file under `folder`, as a repository path, skipping dotfiles as the build does.
    private static func files(under folder: String, in repo: URL) -> [String] {
        // A temporary copy sits under /var, which the walker reports as /private/var.
        let root = repo.appending(path: folder).resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        return walker.compactMap { item -> String? in
            guard let url = item as? URL, (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { return nil }
            return folder + "/" + url.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1)
        }
    }

    private static func sha256(_ repo: URL, _ path: String) throws -> String {
        ControlAgreement.sha256(try Data(contentsOf: repo.appending(path: path))).map { String(format: "%02x", $0) }.joined()
    }

    /// `Web/` without `node_modules`, in a temporary folder, to break on purpose.
    private static func copyOfWeb() throws -> URL {
        let copy = FileManager.default.temporaryDirectory.appending(path: "web-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: copy.appending(path: "Web"), withIntermediateDirectories: true)
        let web = repo.appending(path: "Web")
        for name in try FileManager.default.contentsOfDirectory(atPath: web.path) where name != "node_modules" {
            try FileManager.default.copyItem(at: web.appending(path: name), to: copy.appending(path: "Web/" + name))
        }
        return copy
    }
}

private let webDistRepo = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
