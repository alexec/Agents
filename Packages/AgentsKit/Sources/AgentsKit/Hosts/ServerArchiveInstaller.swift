// The window's side of a server install (049): the Mac downloads and checks, so it needs
// URLSession and CryptoKit, which a Linux server's agentsd neither has nor calls.
#if canImport(Security)
import AgentsKitCore
import Foundation

/// A runtime the vendor ships as an archive, put on a server by the window (049: OpenCode,
/// and Antigravity when its server install is built).
///
/// Unlike a Node toolset, which the server fetches itself (`ToolsetInstaller`), the Mac does
/// the fetching (FR-021): it downloads the archive for the server's platform, checks its size
/// and SHA-256, unpacks it, adds `bin/<shim>` and the manifest, and streams the folder over
/// the existing ssh with `tar -cz`. So the server needs neither outbound access nor `unzip`,
/// and the digest is checked where the app's pin lives. On the server it lands in
/// `<tools>/<runtime>/.part-<id>`, is marked whole with `ok` last, and only then moved into
/// place; a failure anywhere removes the part, and `current` is never touched here.
public struct ServerArchiveInstaller: Sendable {
    public let ssh: SSHCommand

    public init(ssh: SSHCommand) { self.ssh = ssh }

    /// The archive for this server, or why there is none it can use, before anything is
    /// downloaded.
    public static func platform(_ facts: ServerFacts, _ toolset: ArchiveToolset)
        -> Result<ArchiveToolset.Platform, HostProblem> {
        guard let hostFacts = facts.archiveFacts,
              let key = ArchiveToolset.platformKey(for: hostFacts, in: toolset.manifest.platforms.keys),
              let entry = toolset.manifest.platforms[key] else {
            return .failure(.unsupportedSystem(system: facts.system, architecture: facts.architecture.display))
        }
        if let broken = entry.knownBroken { return .failure(.toolsetInstallFailed(broken)) }
        guard facts.freeBytes >= toolset.manifest.minFreeBytes else {
            return .failure(.diskFullForTools(needed: toolset.manifest.minFreeBytes, free: facts.freeBytes))
        }
        return .success(entry)
    }

    /// Install `toolset` beside whatever is there. Does not move `current`.
    public func install(_ toolset: ArchiveToolset, on facts: ServerFacts,
                        progress: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let entry = try Self.platform(facts, toolset).get()
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("server-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let bundle = try await Self.bundle(toolset, entry: entry, in: work, progress: progress)
        progress("Copying \(Self.name(toolset)) to the server")
        let out = try await ssh.run(ssh.runArguments(Self.installScript(toolset)), stdin: bundle)
        guard out.status == 0 else { throw ToolsetInstaller.problem(status: out.status, stderr: out.stderr) }
    }

    // MARK: -

    /// Exit 24: what arrived has no shim, so nothing is kept.
    static func installScript(_ toolset: ArchiveToolset) -> String {
        let id = toolset.id
        return """
            set -e; umask 077; T="$HOME/\(Toolset.serverFolder(runtimeID: toolset.manifest.runtimeID))"; \
            P="$T/.part-\(id)"; mkdir -p "$T"; \
            chmod 700 "$HOME/.agents-server" "$HOME/.agents-server/tools" "$T" 2>/dev/null || true; \
            rm -rf "$P"; mkdir -p "$P"; trap 'rm -rf "$P"' EXIT; \
            tar -xzf - -C "$P"; [ -x "$P/bin/\(toolset.shimName)" ] || exit 24; : > "$P/ok"; \
            rm -rf "$T/\(id)"; trap - EXIT; mv "$P" "$T/\(id)"
            """
    }

    /// The server's folder, whole but for `ok`, as a `.tar.gz` to stream on stdin.
    static func bundle(_ toolset: ArchiveToolset, entry: ArchiveToolset.Platform, in work: URL,
                       progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        let fm = FileManager.default
        let name = name(toolset)
        let tarGz = entry.format == .tarGz
        let archive = work.appendingPathComponent(tarGz ? "archive.tar.gz" : "archive.zip")
        let total = ArchiveToolset.megabytes(entry.size)
        progress("Downloading \(name) (\(total))")
        do {
            try await ArchiveDownload.fetch(entry.url, to: archive) { written in
                progress("Downloading \(name): \(ArchiveToolset.megabytes(written)) of \(total)")
            }
        } catch MacToolsetInstaller.Failure.noInternet(let why) {
            throw HostProblem.noInternet(why)
        } catch MacToolsetInstaller.Failure.archiveDownload(let why) {
            throw HostProblem.toolsetInstallFailed("couldn’t download \(name): \(why)")
        }

        progress("Checking the download")
        let size = (try? fm.attributesOfItem(atPath: archive.path)[.size] as? Int64) ?? -1
        guard size == entry.size, try MacToolsetInstaller.sha256(of: archive) == entry.sha256.lowercased() else {
            throw HostProblem.toolsetChecksum
        }

        progress("Unpacking \(name)")
        let folder = work.appendingPathComponent("toolset", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let unpack = try await InstallStep(executable: tarGz ? "/usr/bin/tar" : "/usr/bin/ditto",
                                           arguments: tarGz ? ["-xzf", archive.path, "-C", folder.path]
                                                            : ["-x", "-k", archive.path, folder.path],
                                           environment: ["COPYFILE_DISABLE": "1"]).run()
        guard unpack.status == 0 else { throw HostProblem.toolsetInstallFailed("couldn’t unpack \(name): \(unpack.lastLine)") }
        try fm.removeItem(at: archive)
        guard fm.isExecutableFile(atPath: folder.appendingPathComponent(entry.command).path) else {
            throw HostProblem.toolsetInstallFailed("the \(name) download has no \(entry.command)")
        }
        try fm.copyItem(at: toolset.folder.appendingPathComponent(Toolset.manifestFile),
                        to: folder.appendingPathComponent(Toolset.manifestFile))
        let bin = folder.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let shim = bin.appendingPathComponent(toolset.shimName)
        try Data((toolset.shimLines(for: entry).joined(separator: "\n") + "\n").utf8).write(to: shim)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)

        // Without macOS's extended attributes, which GNU tar on the server would warn about.
        let tar = work.appendingPathComponent("toolset.tar.gz")
        let pack = try await InstallStep(executable: "/usr/bin/tar",
                                         arguments: ["--no-xattrs", "--no-mac-metadata", "-czf", tar.path,
                                                     "-C", folder.path, "."],
                                         environment: ["COPYFILE_DISABLE": "1"]).run()
        guard pack.status == 0 else { throw HostProblem.toolsetInstallFailed("The app could not pack \(name): \(pack.lastLine)") }
        try? fm.removeItem(at: folder)
        return tar
    }

    static func name(_ toolset: ArchiveToolset) -> String {
        RuntimeCatalog.runtime(id: toolset.manifest.runtimeID)?.name ?? toolset.manifest.runtimeID
    }
}
#endif
