import AgentsKitCore
import AppKit
import Foundation

/// What the window used to do to this Mac's disk and Finder itself, and the App Store
/// window asks this Mac's host to do instead (058, US1, research R12).
extension AppModel {
    /// Whether the window may read `host`'s files off this disk itself. Never in the App
    /// Store window: its sandbox cannot, and the host reads them for it.
    func readsDisk(of host: HostID) -> Bool {
        #if AGENTS_STORE
        false
        #else
        isOnThisMac(host)
        #endif
    }

    /// The shared-settings helpers' way to this Mac's host, in the App Store window.
    func routeSharedFiles() {
        #if AGENTS_STORE
        SharedFiles.onThisMacsHost = { [weak self] url, reveal in
            guard let self else { return }
            if reveal { self.reveal(url, on: .mac) } else { self.open(url, on: .mac) }
        }
        #endif
    }

    /// Reveal in Finder. Only offered for this Mac's host.
    func reveal(_ url: URL, on host: HostID) {
        #if AGENTS_STORE
        Task { _ = try? await client(for: host).call(DaemonAPI.Method.macReveal,
                                                     DaemonAPI.MacPathRequest(path: url.path(percentEncoded: false))) }
        #else
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }

    /// Open with the app macOS would choose, or `app`.
    func open(_ url: URL, on host: HostID, app: String? = nil) {
        #if AGENTS_STORE
        Task { _ = try? await client(for: host).call(DaemonAPI.Method.macOpen,
                                                     DaemonAPI.MacPathRequest(path: url.path(percentEncoded: false), app: app)) }
        #else
        if let app, let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app)
            ?? NSWorkspace.shared.fullPath(forApplication: app).map(URL.init(fileURLWithPath:)) {
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    /// Terminal, on this Mac's host.
    func openTerminal(at url: URL? = nil, on host: HostID = .mac) {
        #if AGENTS_STORE
        Task { _ = try? await client(for: host).call(DaemonAPI.Method.macTerminal,
                                                     DaemonAPI.MacTerminalRequest(path: url?.path(percentEncoded: false))) }
        #else
        NSWorkspace.shared.open(URL(filePath: "/System/Applications/Utilities/Terminal.app"))
        #endif
    }

    /// A text file by its full path on `host`: `files/readText`, or this disk.
    func readText(_ url: URL, on host: HostID) async -> String? {
        if readsDisk(of: host) { return try? String(contentsOf: url, encoding: .utf8) }  // store-ok: readsDisk(of:) is false in the store window
        let answer = try? await client(for: host).call(DaemonAPI.Method.filesReadText,
                                                       DaemonAPI.FilesTextRequest(path: url.path(percentEncoded: false)),
                                                       returning: DaemonAPI.FilesText.self)
        return answer?.text
    }

    /// Writes a text file on `host`; `onlyIfAbsent` leaves one that is there alone.
    func saveText(_ text: String, to url: URL, on host: HostID, onlyIfAbsent: Bool = false) async -> Bool {
        if readsDisk(of: host) {
            if onlyIfAbsent, FileManager.default.fileExists(atPath: url.path) { return true }  // store-ok: readsDisk(of:) is false in the store window
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)  // store-ok: readsDisk(of:) is false in the store window
            return (try? Data(text.utf8).write(to: url, options: .atomic)) != nil  // store-ok: readsDisk(of:) is false in the store window
        }
        return (try? await client(for: host).call(DaemonAPI.Method.filesSaveText,
                                                  DaemonAPI.FilesSaveTextRequest(path: url.path(percentEncoded: false), text: text,
                                                                                 onlyIfAbsent: onlyIfAbsent))) != nil
    }
}

/// The person's home folder, for writing a path with `~`. In the sandbox the home the
/// app is told is its container, so this asks the account instead.
enum RealHome {
    static let path: String = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }()
}
