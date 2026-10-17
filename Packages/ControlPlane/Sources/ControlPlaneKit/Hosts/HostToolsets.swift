import AgentsKit
import AgentsKitCore
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The runtimes' toolsets `hosts/install` puts on a server before the host starts (#1268),
/// as the Go control plane's does (#1240) and the window's `ToolsetInstaller` does for a
/// server it holds (043): the same script, the same `~/.agents-server/tools/<runtime>/<id>`
/// layout and the same toolset id, so a server added through the control plane can run
/// Claude with nothing installed by the person.
///
/// - The toolsets come from Agents Host's own (`Contents/Resources/toolsets`, beside
///   `Contents/Helpers/agents-control`), a container's `/toolsets`, or
///   `AGENTS_CONTROL_TOOLSETS`.
/// - A toolset that cannot be installed is logged, and the host still starts: the runtime
///   says why when it is chosen. The same as for the shipped MCP servers.
/// - A toolset that `current` already points at is not fetched again.
/// - A server with no xz, curl or wget (a minimal Debian has no xz) gets Node from the
///   control plane: downloaded here, checked against the manifest's pinned SHA-256, and
///   sent unpacked in the bundle. `npm ci` still runs on the server.
public struct HostToolsets: Sendable {
    /// The runtimes put on a server: Claude, the default runtime. Each is about 500 MB and a
    /// minute of npm.
    public static let defaultRuntimes = [RuntimeCatalog.claude.id]

    let folder: URL?
    let runtimes: [String]
    /// Where Node's tarballs are published.
    let nodeDist: URL
    let log: @Sendable (String) -> Void

    public init(folder: URL?, runtimes: [String] = HostToolsets.defaultRuntimes,
                nodeDist: URL = URL(string: "https://nodejs.org/dist")!,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.folder = folder
        self.runtimes = runtimes
        self.nodeDist = nodeDist
        self.log = log
    }

    /// Agents Host's `Resources/toolsets`, a container's `/toolsets`, or
    /// `AGENTS_CONTROL_TOOLSETS`: the first with Claude's manifest in it.
    public static func folder(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates: [URL] = []
        if let given = environment["AGENTS_CONTROL_TOOLSETS"] { candidates.append(URL(fileURLWithPath: given, isDirectory: true)) }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        candidates.append(executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/toolsets", isDirectory: true))
        candidates.append(URL(fileURLWithPath: "/toolsets", isDirectory: true))
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("claude/\(Toolset.manifestFile)").path)
        }
    }

    /// Each toolset named, on the server, with `current` pointed at it.
    func install(over ssh: SSHCommand, facts: ServerFacts, name: String) async {
        #if canImport(CryptoKit)
        guard let folder else { return }
        let all = Toolset.loadAll(from: folder)
        var facts = facts
        for toolset in runtimes.compactMap({ all[$0] }) {
            let runtime = RuntimeCatalog.runtime(id: toolset.manifest.runtimeID)?.name ?? toolset.manifest.runtimeID
            do {
                try await install(toolset, over: ssh, facts: facts)
                // What the server had free goes down by what this one needs, for the next.
                facts.freeBytes -= toolset.manifest.minFreeBytes
            } catch let problem as HostProblem {
                log("hosts/install: \(runtime) on \(name): \(HostInstall.say(problem))")
            } catch {
                log("hosts/install: \(runtime) on \(name): \(error.localizedDescription)")
            }
        }
        #endif
    }

    #if canImport(CryptoKit)
    func install(_ toolset: Toolset, over ssh: SSHCommand, facts: ServerFacts) async throws {
        let installer = ToolsetInstaller(ssh: ssh)
        let runtimeID = toolset.manifest.runtimeID
        let installed = facts.toolsetID(for: runtimeID) == toolset.id
        if !installed, !(await installer.isInstalled(toolset.id, runtimeID: runtimeID)) {
            if let refusal = ToolsetInstaller.refusal(facts, toolset, nodeGiven: true) { throw refusal }
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("agents-toolset-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: scratch) }
            var node: URL?
            let unpacks = facts.downloader != nil ? await Self.hasXZ(ssh) : false
            if !unpacks {
                node = try await fetchNode(toolset, for: facts.architecture, into: scratch)
            }
            try await installer.install(toolset, on: facts, node: node)
        }
        try await installer.swap(to: toolset.id, runtimeID: runtimeID)
    }

    /// Whether the server can unpack Node's `.tar.xz` itself.
    static func hasXZ(_ ssh: SSHCommand) async -> Bool {
        let out = try? await ssh.run(ssh.runArguments("command -v xz >/dev/null 2>&1"))
        return out?.status == 0
    }

    /// The control plane's side of a toolset for a server that cannot fetch or unpack Node
    /// itself: Node's `.tar.xz`, checked against the manifest's SHA-256 and unpacked to a
    /// plain `node.tar` in `folder`.
    func fetchNode(_ toolset: Toolset, for architecture: Architecture, into folder: URL) async throws -> URL {
        guard let tarball = toolset.manifest.nodeTarball(for: architecture),
              let sha = toolset.manifest.nodeSHA256(for: architecture) else {
            throw HostProblem.toolsetInstallFailed("This toolset has no Node for \(architecture.display).")
        }
        let data: Data
        do {
            let (body, response) = try await URLSession.shared.data(from: nodeDist.appendingPathComponent(tarball))
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw HostProblem.toolsetInstallFailed("couldn’t download Node.js: HTTP \(http.statusCode)")
            }
            data = body
        } catch let problem as HostProblem {
            throw problem
        } catch {
            throw HostProblem.toolsetInstallFailed("couldn’t download Node.js: \(error.localizedDescription)")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha.lowercased() else { throw HostProblem.toolsetChecksum }
        let packed = folder.appendingPathComponent("node.tar.xz")
        try data.write(to: packed)
        let plain = folder.appendingPathComponent("node.tar")
        // bsdtar reads the .tar.xz and writes its entries again as a plain tar.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cf", plain.path, "@\(packed.path)"]
        let errors = Pipe()
        process.standardError = errors
        let status: Int32 = try await withCheckedThrowingContinuation { done in
            process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { process.terminationHandler = nil; done.resume(throwing: error) }
        }
        try? FileManager.default.removeItem(at: packed)
        guard status == 0 else {
            let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw HostProblem.toolsetInstallFailed("couldn’t unpack Node.js: \(said.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return plain
    }
    #endif
}
