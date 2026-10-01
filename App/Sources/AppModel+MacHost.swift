import AgentsKitCore
import AppKit
import Foundation

/// What the window used to do to this Mac's disk and Finder itself, and the App Store
/// window asks this Mac's host to do instead (058, US1, research R12).
extension AppModel {
    /// For walks: `AGENTS_CONTROL=<code>` pairs without the first run, as T029 did. Started
    /// with the app, so it runs with no window on screen (a locked Mac, a scratch walk).
    func pairForWalk() async {
        guard needsFirstRun, let text = ProcessInfo.processInfo.environment["AGENTS_CONTROL"] else { return }
        guard let code = ControlCode(text: text) else {
            FileHandle.standardError.write(Data("walk: AGENTS_CONTROL is not a code\n".utf8))
            return
        }
        do {
            let membership = try await ControlConfig.pair(with: code)
            FileHandle.standardError.write(Data("walk: paired as \(membership.client?.uuidString ?? "?"), machine \(MachineID.current)\n".utf8))
            await adopt(.remote(membership))
        } catch {
            FileHandle.standardError.write(Data("walk: could not pair: \(error)\n".utf8))
        }
    }

    /// The shared-settings helpers' way to this Mac's host, in the App Store window.
    func routeSharedFiles() {
        SharedFiles.onThisMacsHost = { [weak self] url, reveal in
            guard let self else { return }
            if reveal { self.reveal(url, on: .mac) } else { self.open(url, on: .mac) }
        }
    }

    /// Reveal in Finder. Only offered for this Mac's host.
    func reveal(_ url: URL, on host: HostID) {
        Task { _ = try? await client(for: host).call(DaemonAPI.Method.macReveal,
                                                     DaemonAPI.MacPathRequest(path: url.path(percentEncoded: false))) }
    }

    /// Open with the app macOS would choose, or `app`.
    func open(_ url: URL, on host: HostID, app: String? = nil) {
        Task { _ = try? await client(for: host).call(DaemonAPI.Method.macOpen,
                                                     DaemonAPI.MacPathRequest(path: url.path(percentEncoded: false), app: app)) }
    }

    /// Terminal, on this Mac's host.
    func openTerminal(at url: URL? = nil, on host: HostID = .mac) {
        Task { _ = try? await client(for: host).call(DaemonAPI.Method.macTerminal,
                                                     DaemonAPI.MacTerminalRequest(path: url?.path(percentEncoded: false))) }
    }

    /// A text file by its full path on `host`: `files/readText`.
    func readText(_ url: URL, on host: HostID) async -> String? {
        let answer = try? await client(for: host).call(DaemonAPI.Method.filesReadText,
                                                       DaemonAPI.FilesTextRequest(path: url.path(percentEncoded: false)),
                                                       returning: DaemonAPI.FilesText.self)
        return answer?.text
    }

    /// Writes a text file on `host`; `onlyIfAbsent` leaves one that is there alone.
    func saveText(_ text: String, to url: URL, on host: HostID, onlyIfAbsent: Bool = false) async -> Bool {
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
