import AgentsKitCore
import CryptoKit
import Foundation

/// Claude for somebody with no Node (048): the server toolset of 043, installed on this Mac.
///
/// The same shape as `ToolsetInstaller`'s script, in Swift rather than sh. Node is
/// downloaded from nodejs.org and checked against the SHA-256 in `mac-node.json`, the
/// adapter is installed with `npm ci` against the app's lock, and `bin/npx` is the same
/// shim. It is built in `<tools>/claude/.part-<id>`, removed on any failure, marked whole
/// with `ok` last, then moved into place and made `current`. No Homebrew, no admin
/// password, and nothing of the person's — PATH, profile, npm — is touched.
public struct MacToolsetInstaller: Sendable {
    public var toolset: Toolset
    /// `StoreLocations.tools`: the daemon's own, so a scratch root installs fresh.
    public var tools: URL
    /// Where Node is published. A `file://` folder in tests.
    public var nodeDist: URL
    public var architecture: String
    public var environment: [String: String]

    public init(toolset: Toolset,
                tools: URL,
                nodeDist: URL = URL(string: "https://nodejs.org/dist/")!,
                architecture: String = Toolset.MacNode.hostArchitecture,
                environment: [String: String] = LoginShellPath.installEnvironment()) {
        self.toolset = toolset
        self.tools = tools
        self.nodeDist = nodeDist
        self.architecture = architecture
        self.environment = environment
    }

    /// Why it cannot be installed, in a sentence. The same kinds as a server's
    /// (`ToolsetInstaller.problem`), said about this Mac.
    public enum Failure: Error, Equatable, Sendable {
        case noMacPin
        case noInternet(String)
        case download(String)
        case checksum
        case npm(String)
        case noSpace
        case other(String)

        public var sentence: String {
            switch self {
            case .noMacPin: "This build of the app carries no Node.js for this Mac."
            case .noInternet: "Couldn’t reach the internet to download Claude."
            case .download(let detail): "Couldn’t download Node.js: \(detail)"
            case .checksum: "The download didn’t match its checksum, so nothing was installed."
            case .npm(let detail): "Installing the Claude adapter failed: \(detail)"
            case .noSpace: "There isn’t room on this Mac to install Claude."
            case .other(let detail): "Installing Claude failed: \(detail)"
            }
        }
    }

    public var folder: URL { tools.appendingPathComponent(toolset.manifest.runtimeID, isDirectory: true) }

    /// Install, make it `current`, and remove any other. Returns the shim's path.
    @discardableResult
    public func install(progress: @Sendable (String) -> Void = { _ in }) async throws -> String {
        guard let node = toolset.macNode, let sha = node.sha256[architecture] else { throw Failure.noMacPin }
        let fm = FileManager.default
        let id = toolset.id
        let finished = folder.appendingPathComponent(id, isDirectory: true)
        if !fm.fileExists(atPath: finished.appendingPathComponent("ok").path) {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let part = folder.appendingPathComponent(".part-\(id)", isDirectory: true)
            try? fm.removeItem(at: part)
            do {
                try await build(in: part, node: node, sha: sha, progress: progress)
                try? fm.removeItem(at: finished)
                try fm.moveItem(at: part, to: finished)
            } catch {
                try? fm.removeItem(at: part)
                if (error as NSError).code == NSFileWriteOutOfSpaceError { throw Failure.noSpace }
                throw error
            }
        }
        try point(currentAt: id)
        removeOthers(except: id)
        return finished.appendingPathComponent("bin/npx").path
    }

    private func build(in part: URL, node: Toolset.MacNode, sha: String,
                       progress: @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        let lib = part.appendingPathComponent("lib", isDirectory: true)
        try fm.createDirectory(at: lib, withIntermediateDirectories: true)
        for file in [Toolset.packageFile, Toolset.lockFile] {
            try fm.copyItem(at: toolset.folder.appendingPathComponent(file), to: lib.appendingPathComponent(file))
        }
        try fm.copyItem(at: toolset.folder.appendingPathComponent(Toolset.manifestFile),
                        to: part.appendingPathComponent(Toolset.manifestFile))

        progress("Downloading Node.js \(node.version)")
        let tarball = part.appendingPathComponent("node.tar.gz")
        try await download(nodeDist.appendingPathComponent(node.tarball(for: architecture)), to: tarball)

        progress("Checking the download")
        guard try Self.sha256(of: tarball) == sha.lowercased() else { throw Failure.checksum }

        progress("Unpacking Node.js")
        let nodeFolder = part.appendingPathComponent("node", isDirectory: true)
        try fm.createDirectory(at: nodeFolder, withIntermediateDirectories: true)
        let untar = try await InstallStep(executable: "/usr/bin/tar",
                                          arguments: ["-xzf", tarball.path, "-C", nodeFolder.path,
                                                      "--strip-components=1"],
                                          environment: environment).run()
        guard untar.status == 0 else { throw Self.problem(untar.output, else: .download(untar.lastLine)) }
        try fm.removeItem(at: tarball)

        progress("Installing the Claude adapter")
        var npmEnvironment = environment
        npmEnvironment["PATH"] = nodeFolder.appendingPathComponent("bin").path + ":" + (environment["PATH"] ?? "")
        let npm = try await InstallStep(
            executable: nodeFolder.appendingPathComponent("bin/npm").path,
            arguments: Toolset.npmCIArguments + ["--prefix", lib.path, "--cache", part.appendingPathComponent(".npm").path],
            environment: npmEnvironment,
            directory: part,
            timeout: .seconds(600)).run()
        guard npm.status == 0 else {
            if npm.timedOut { throw Failure.npm("it took more than ten minutes") }
            throw Self.npmProblem(npm.output)
        }
        try? fm.removeItem(at: part.appendingPathComponent(".npm"))

        let bin = part.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let shim = bin.appendingPathComponent("npx")
        try Data((toolset.shimLines.joined(separator: "\n") + "\n").utf8).write(to: shim)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
        // Last: a toolset without this is never used.
        try Data().write(to: part.appendingPathComponent("ok"))
    }

    private func download(_ url: URL, to destination: URL) async throws {
        let fetched: URL
        let response: URLResponse
        do {
            (fetched, response) = try await URLSession.shared.download(from: url)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .networkConnectionLost, .timedOut:
                throw Failure.noInternet(error.localizedDescription)
            default:
                throw Failure.download(error.localizedDescription)
            }
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: fetched)
            throw Failure.download("nodejs.org answered \(http.statusCode) for \(url.lastPathComponent)")
        }
        try FileManager.default.moveItem(at: fetched, to: destination)
    }

    /// `ln -sfn <id> current`, by writing the new link beside and renaming it over, so
    /// there is never a moment without one.
    private func point(currentAt id: String) throws {
        let fm = FileManager.default
        let current = folder.appendingPathComponent("current")
        let next = folder.appendingPathComponent(".current-\(UUID().uuidString)")
        try fm.createSymbolicLink(atPath: next.path, withDestinationPath: id)
        guard rename(next.path, current.path) == 0 else {
            try? fm.removeItem(at: next)
            throw Failure.other("couldn’t make \(id) the current toolset")
        }
    }

    /// Every other toolset and half-built one. About half a gigabyte each.
    private func removeOthers(except id: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name != id && name != "current" {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The same reading of npm's output as `ToolsetInstaller.problem`'s exit 23.
    static func npmProblem(_ output: String) -> Failure {
        let last = InstallStep.Outcome(status: 1, timedOut: false, output: output).lastLine
        if output.contains("No space left on device") || output.contains("ENOSPC") { return .noSpace }
        if output.contains("EINTEGRITY") { return .checksum }
        if output.contains("ENOTFOUND") || output.contains("EAI_AGAIN") || output.contains("ECONNREFUSED")
            || output.contains("ETIMEDOUT") {
            return .noInternet(last)
        }
        return .npm(last)
    }

    private static func problem(_ output: String, else fallback: Failure) -> Failure {
        output.contains("No space left on device") ? .noSpace : fallback
    }
}
