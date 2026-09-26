import AgentsKitCore
import Foundation

/// What the window puts on a server so Claude can run there with nothing installed by the
/// person (043, contracts/ssh.md §§ 2–4).
///
/// The server downloads it itself (D2): Node.js from nodejs.org, checked against the
/// SHA-256 the app carries, then the ACP adapter with `npm ci` against the app's lock,
/// whose `integrity` fields npm checks. Everything lands in
/// `~/.agents-server/tools/claude/<id>/`, private to the person's account, touching no
/// profile, PATH or tool of theirs. It is built in a `.part-<id>` folder that is removed on
/// any failure, marked whole with an `ok` file last, and only then moved into place, so a
/// toolset without `ok` is never used.
public struct ToolsetInstaller: Sendable {
    public let ssh: SSHCommand

    public init(ssh: SSHCommand) { self.ssh = ssh }

    /// Why this server cannot have the toolset, before anything is downloaded; nil when
    /// it can.
    public static func refusal(_ facts: ServerFacts, _ toolset: Toolset) -> HostProblem? {
        guard facts.canInstallClaude else { return .unsupportedLibc(facts.libc.display) }
        guard facts.downloader != nil else { return .noDownloader }
        guard facts.freeBytes >= toolset.manifest.minFreeBytes else {
            return .diskFullForTools(needed: toolset.manifest.minFreeBytes, free: facts.freeBytes)
        }
        guard toolset.manifest.nodeTarball(for: facts.architecture) != nil,
              toolset.manifest.nodeSHA256(for: facts.architecture) != nil else {
            return .unsupportedSystem(system: facts.system, architecture: facts.architecture.display)
        }
        return nil
    }

    /// Install `toolset` beside whatever is there. Does not move `current`.
    public func install(_ toolset: Toolset, on facts: ServerFacts) async throws {
        if let refusal = Self.refusal(facts, toolset) { throw refusal }
        let bundle = try await Self.bundle(toolset)
        defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
        let out = try await ssh.run(ssh.runArguments(Self.installScript(toolset, facts)), stdin: bundle)
        guard out.status == 0 else { throw Self.problem(status: out.status, stderr: out.stderr) }
    }

    /// Whether a whole toolset with this id is already on the server, beside `current` or
    /// as it: an update installed earlier and still waiting to be swapped in.
    public func isInstalled(_ id: String) async -> Bool {
        let out = try? await ssh.run(ssh.runArguments(
            "[ -f \"$HOME/\(Toolset.serverFolder(runtimeID: "claude"))/\(id)/ok\" ]"))
        return out?.status == 0
    }

    /// Point `current` at an installed toolset. Last, and on its own, so an update can wait
    /// for a turn to end between installing and swapping.
    public func swap(to id: String) async throws {
        try await check("""
            set -e; T="$HOME/\(Toolset.serverFolder(runtimeID: "claude"))"; \
            [ -f "$T/\(id)/ok" ]; ln -sfn \(ServerInstaller.quote(id)) "$T/current"
            """)
    }

    /// Remove every toolset but this one. After a good start on it, never with the swap.
    public func removeOthers(except id: String) async throws {
        try await check("""
            T="$HOME/\(Toolset.serverFolder(runtimeID: "claude"))"; cd "$T" 2>/dev/null || exit 0; \
            for d in */ .part-*; do d=${d%/}; [ -e "$d" ] || continue; \
            [ "$d" = \(ServerInstaller.quote(id)) ] || [ "$d" = current ] || rm -rf -- "$d"; done
            """)
    }

    // MARK: -

    /// contracts/ssh.md § 2. Exit 21: the download; 22: the checksum; 23: npm.
    static func installScript(_ toolset: Toolset, _ facts: ServerFacts) -> String {
        let manifest = toolset.manifest
        let tarball = manifest.nodeTarball(for: facts.architecture) ?? ""
        let sha = manifest.nodeSHA256(for: facts.architecture) ?? ""
        let id = toolset.id
        // Only the one the probe found, so a failure is that tool's own words.
        let fetch = facts.downloader == "wget" ? "wget -qO- \"$1\"" : "curl -fsSL \"$1\""
        let npm = Toolset.npmCIArguments.joined(separator: " ")
        let shim = toolset.shimLines.map { "'\($0)'" }.joined(separator: " ")
        return """
            set -e; umask 077; T="$HOME/\(Toolset.serverFolder(runtimeID: "claude"))"; P="$T/.part-\(id)"; \
            mkdir -p "$T"; chmod 700 "$HOME/.agents-server" "$HOME/.agents-server/tools" "$T" 2>/dev/null || true; \
            rm -rf "$P"; mkdir -p "$P/lib"; trap 'rm -rf "$P"' EXIT; cd "$P"; \
            tar -xf - -C lib; mv lib/\(Toolset.manifestFile) .; \
            fetch() { \(fetch) 2>"$P/fetch.err"; }; \
            fetch 'https://nodejs.org/dist/\(tarball)' > node.tar.xz || { tail -1 "$P/fetch.err" >&2; exit 21; }; \
            echo '\(sha)  node.tar.xz' | sha256sum -c - >/dev/null 2>&1 || exit 22; \
            mkdir node; tar -xJf node.tar.xz -C node --strip-components=1; rm -f node.tar.xz fetch.err; \
            PATH="$P/node/bin:$PATH" npm \(npm) --prefix "$P/lib" \
            --cache "$P/.npm" >"$P/npm.log" 2>&1 || { tail -5 "$P/npm.log" >&2; exit 23; }; \
            rm -rf "$P/.npm" "$P/npm.log"; mkdir "$P/bin"; \
            printf '%s\\n' \(shim) > "$P/bin/npx"; \
            chmod 700 "$P/bin/npx"; : > "$P/ok"; \
            rm -rf "$T/\(id)"; trap - EXIT; mv "$P" "$T/\(id)"
            """
    }

    /// The three files, as a tar to stream on stdin. Without macOS's extended attributes,
    /// which GNU tar on the server would warn about.
    static func bundle(_ toolset: Toolset) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("toolset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tar = folder.appendingPathComponent("toolset.tar")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tar")
        process.arguments = ["--no-xattrs", "--no-mac-metadata", "-cf", tar.path, "-C", toolset.folder.path,
                             Toolset.manifestFile, Toolset.packageFile, Toolset.lockFile]
        process.environment = ["COPYFILE_DISABLE": "1"]
        let status: Int32 = try await withCheckedThrowingContinuation { done in
            process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { process.terminationHandler = nil; done.resume(throwing: error) }
        }
        guard status == 0 else {
            throw HostProblem.toolsetInstallFailed("The app could not pack its Claude toolset.")
        }
        return tar
    }

    /// contracts/ssh.md § 4.
    static func problem(status: Int32, stderr: String) -> HostProblem {
        let last = stderr.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        if stderr.contains("No space left on device") { return .diskFullForTools(needed: 0, free: 0) }
        switch status {
        case 21:
            if stderr.contains("Could not resolve host") || stderr.contains("unable to resolve")
                || stderr.contains("Temporary failure in name resolution") || stderr.contains("Failed to connect") {
                return .noInternet(last)
            }
            return .toolsetInstallFailed("couldn’t download Node.js: \(last)")
        case 22:
            return .toolsetChecksum
        case 23:
            if stderr.contains("EINTEGRITY") { return .toolsetChecksum }
            if stderr.contains("ENOTFOUND") || stderr.contains("EAI_AGAIN") || stderr.contains("ECONNREFUSED")
                || stderr.contains("ETIMEDOUT") {
                return .noInternet(last)
            }
            return .toolsetInstallFailed(last)
        default:
            return SSHCommand.classify(status: status, stderr: stderr, agentHasKeys: true) ?? .toolsetInstallFailed(last)
        }
    }

    private func check(_ script: String) async throws {
        let out = try await ssh.run(ssh.runArguments(script))
        guard out.status == 0 else {
            throw SSHCommand.classify(status: out.status, stderr: out.stderr, agentHasKeys: true)
                ?? .toolsetInstallFailed(out.stderr)
        }
    }
}
