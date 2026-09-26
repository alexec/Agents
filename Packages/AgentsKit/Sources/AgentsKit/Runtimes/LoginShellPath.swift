import Foundation

/// The PATH the user's shell has, which is not the PATH this app inherits.
///
/// An app launched from the Finder gets launchd's PATH: `/usr/bin:/bin:/usr/sbin:/sbin`
/// and nothing else. Not one of the three runtimes is in it. On this Mac they live in
/// `~/.local/bin`, `~/.grok/bin` and `/opt/homebrew/bin`, so without this the app finds
/// nothing while the terminal two inches away finds everything.
public enum LoginShellPath {
    private static let cache = PathCache()

    /// Places worth looking even when the shell says nothing useful.
    public static let fallbacks: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin", "/usr/local/bin",
                "\(home)/.local/bin", "\(home)/.grok/bin", "\(home)/.bun/bin",
                "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    }()

    /// Read once and kept. A login shell costs about a tenth of a second, and the
    /// answer does not change while the app is running.
    public static func directories() -> [String] {
        if let cached = cache.value { return cached }
        // First place wins, as it does for the shell. A login PATH often names a
        // directory twice (a profile that prepends what path_helper already put there).
        var directories: [String] = []
        for directory in (readFromLoginShell() ?? []) + fallbacks where !directories.contains(directory) {
            directories.append(directory)
        }
        cache.value = directories
        return directories
    }

    /// A login shell, not an interactive one. `-i` runs the user's interactive
    /// configuration, which can prompt, print, or sit waiting, and a runtime list is
    /// not worth hanging the app for.
    private static func readFromLoginShell() -> [String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.split(separator: ":").map(String.init)
    }

    /// The environment a runtime is started with: the app's own, with the shell's PATH
    /// put back, because a runtime that shells out needs it as much as we do.
    public static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directories().joined(separator: ":")
        return environment
    }
}

private final class PathCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String]?

    var value: [String]? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}
