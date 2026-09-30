// The Mac's own archive installer (049), like `MacToolsetInstaller`: a Linux server's
// agentsd has no CryptoKit or `ditto` and installs through `ToolsetInstaller`.
#if canImport(Security)
import AgentsKitCore
import Foundation

/// A runtime the vendor ships as a signed archive, installed on this Mac (049): Google's
/// Antigravity ACP server, and OpenCode.
///
/// `MacToolsetInstaller`'s shape without Node or npm: the archive for this Mac is
/// downloaded from the vendor, checked against the size and SHA-256 the app carries, unpacked
/// with `ditto` (zip) or `tar` (`.tar.gz`), given `bin/<shim>`, marked whole with `ok` last, moved into place and made
/// `current`. The folder layout is the same, so discovery, **Update** and `tidy` treat it
/// like any other toolset.
public struct MacArchiveInstaller: Sendable {
    public var toolset: ArchiveToolset
    /// `StoreLocations.tools`.
    public var tools: URL
    /// The manifest key to install: this Mac's most specific one unless a test says otherwise.
    public var platform: String
    public var environment: [String: String]
    /// Free bytes where `tools` lives. A parameter so tests can say "none".
    public var freeBytes: @Sendable (URL) -> Int64?

    public init(toolset: ArchiveToolset,
                tools: URL,
                platform: String? = nil,
                environment: [String: String] = LoginShellPath.installEnvironment(),
                freeBytes: @escaping @Sendable (URL) -> Int64? = MacArchiveInstaller.volumeFreeBytes) {
        self.toolset = toolset
        self.tools = tools
        self.platform = platform ?? toolset.macPlatformKey
        self.environment = environment
        self.freeBytes = freeBytes
    }

    public var folder: URL { tools.appendingPathComponent(toolset.manifest.runtimeID, isDirectory: true) }

    public var runtimeName: String {
        RuntimeCatalog.runtime(id: toolset.manifest.runtimeID)?.name ?? toolset.manifest.runtimeID
    }

    /// This Mac's archive, or why there is none it can use.
    public var available: Result<ArchiveToolset.Platform, MacToolsetInstaller.Failure> {
        guard let entry = toolset.manifest.platforms[platform] else {
            return .failure(.unavailable("\(vendor) publishes no \(runtimeName) for this Mac."))
        }
        if let broken = entry.knownBroken { return .failure(.unavailable(broken)) }
        return .success(entry)
    }

    /// Who publishes it, from where it is downloaded: "Google", "GitHub", or the host.
    public var vendor: String { ArchiveToolset.vendor(of: toolset) }

    /// Install, and make it `current`. Returns the shim's path.
    @discardableResult
    public func install(progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        let entry = try available.get()
        let fm = FileManager.default
        let id = toolset.id
        try fm.createDirectory(at: self.folder, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let folder = MacToolsetInstaller.realPath(self.folder)
        let finished = folder.appendingPathComponent(id, isDirectory: true)
        if !fm.fileExists(atPath: finished.appendingPathComponent("ok").path) {
            if let free = freeBytes(folder), free < toolset.manifest.minFreeBytes {
                throw MacToolsetInstaller.Failure.needsRoom(toolset.manifest.minFreeBytes)
            }
            let part = folder.appendingPathComponent(".part-\(id)", isDirectory: true)
            try? fm.removeItem(at: part)
            do {
                try await build(in: part, entry: entry, progress: progress)
                try? fm.removeItem(at: finished)
                try fm.moveItem(at: part, to: finished)
            } catch {
                try? fm.removeItem(at: part)
                if (error as NSError).code == NSFileWriteOutOfSpaceError { throw MacToolsetInstaller.Failure.noSpace }
                throw error
            }
        }
        try MacToolsetInstaller.point(currentAt: id, in: self.folder)
        return finished.appendingPathComponent("bin/\(toolset.shimName)").path
    }

    private func build(in part: URL, entry: ArchiveToolset.Platform,
                       progress: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: part, withIntermediateDirectories: true)
        try fm.copyItem(at: toolset.folder.appendingPathComponent(Toolset.manifestFile),
                        to: part.appendingPathComponent(Toolset.manifestFile))

        let total = ArchiveToolset.megabytes(entry.size)
        progress("Downloading \(runtimeName) (\(total))")
        let tarGz = entry.format == .tarGz
        let archive = part.appendingPathComponent(tarGz ? "archive.tar.gz" : "archive.zip")
        try await ArchiveDownload.fetch(entry.url, to: archive) { written in
            progress("Downloading \(runtimeName): \(ArchiveToolset.megabytes(written)) of \(total)")
        }

        progress("Checking the download")
        let size = (try? fm.attributesOfItem(atPath: archive.path)[.size] as? Int64) ?? -1
        guard size == entry.size, try MacToolsetInstaller.sha256(of: archive) == entry.sha256.lowercased() else {
            throw MacToolsetInstaller.Failure.checksum
        }

        progress("Unpacking \(runtimeName)")
        // Unpacked by the app, not a browser, so nothing is quarantined and an ad-hoc signed
        // program (OpenCode's, research R1) runs without a Gatekeeper prompt.
        let unzip = try await InstallStep(executable: tarGz ? "/usr/bin/tar" : "/usr/bin/ditto",
                                          arguments: tarGz ? ["-xzf", archive.path, "-C", part.path]
                                                           : ["-x", "-k", archive.path, part.path],
                                          environment: environment).run()
        guard unzip.status == 0 else {
            if unzip.output.contains("No space left on device") { throw MacToolsetInstaller.Failure.noSpace }
            throw MacToolsetInstaller.Failure.other("couldn’t unpack it: \(unzip.lastLine)")
        }
        try fm.removeItem(at: archive)
        guard fm.isExecutableFile(atPath: part.appendingPathComponent(entry.command).path) else {
            throw MacToolsetInstaller.Failure.other("the download has no \(entry.command)")
        }

        let bin = part.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let shim = bin.appendingPathComponent(toolset.shimName)
        try Data((toolset.shimLines(for: entry).joined(separator: "\n") + "\n").utf8).write(to: shim)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
        // Last: a toolset without this is never used.
        try Data().write(to: part.appendingPathComponent("ok"))
    }

    public var currentID: String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("current").path)
    }

    /// As `MacToolsetInstaller.tidy`: everything but `current`, at the daemon's start.
    public func tidy() {
        MacToolsetInstaller.tidy(folder: folder, keeping: currentID)
    }

    public static let volumeFreeBytes: @Sendable (URL) -> Int64? = { url in
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}

/// A download to a file that says how far it has got, every few megabytes.
enum ArchiveDownload {
    static func fetch(_ url: URL, to destination: URL,
                      progress: @escaping @Sendable (Int64) -> Void) async throws {
        let delegate = ProgressDelegate(progress: progress)
        let fetched: URL
        let response: URLResponse
        do {
            (fetched, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .networkConnectionLost, .timedOut:
                throw MacToolsetInstaller.Failure.noInternet(error.localizedDescription)
            default:
                throw MacToolsetInstaller.Failure.archiveDownload(error.localizedDescription)
            }
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: fetched)
            throw MacToolsetInstaller.Failure.archiveDownload("\(url.host() ?? "the server") answered \(http.statusCode)")
        }
        try FileManager.default.moveItem(at: fetched, to: destination)
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Int64) -> Void
        private var said: Int64 = 0
        private let lock = NSLock()

        init(progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            lock.lock()
            let due = totalBytesWritten - said >= 4_000_000
            if due { said = totalBytesWritten }
            lock.unlock()
            if due { progress(totalBytesWritten) }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}
    }
}
#endif
