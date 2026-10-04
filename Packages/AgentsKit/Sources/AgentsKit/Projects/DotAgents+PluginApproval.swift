import AgentsKitCore
import Foundation

/// What a project's plugin is, for approving it (security review, S2): one digest over
/// everything in its folder, and a few words on what it brings.
///
/// The digest is of the folder as a runtime will load it: every file's path and content,
/// every folder's path, and every link's path and destination — and, for a link to a
/// file, that file's content too, since a runtime follows it. A link to a folder is taken
/// as its destination only; a hook reached through one is still named by where it points.
/// `.DS_Store` is left out, so Finder looking at a folder does not make it wait again.
///
/// A plugin's `gemini-extension.json` is written, when it has none, before the digest is
/// taken: the app writes it on the way to every Gemini session, and a manifest the app
/// wrote must not read as the plugin having changed.
///
/// It is asked for on every session start and every warm check (#202), and reading every
/// file of a plugin carrying `node_modules` stalls the daemon. So the digest is kept per
/// folder against a stamp of what `lstat` says of every entry (inode, size, modified and
/// changed times), which reads no file; it is taken again only when the stamp moves. The
/// changed time cannot be set back by anyone writing the folder, so an edit that restores
/// a file's size and modified time still moves the stamp.
extension DotAgents {
    static let ignoredInDigest: Set<String> = [".DS_Store"]

    /// The digest of `plugin`'s folder, or nil when it cannot be read at all.
    public static func pluginDigest(_ plugin: URL) -> String? {
        attempt("write \(geminiManifest) for \(plugin.lastPathComponent)") { try writeGeminiManifest(for: plugin) }
        let key = plugin.standardizedFileURL.path
        let stamp = pluginStamp(plugin)
        if let stamp, let digest = digestCache.digest(key, stamp: stamp) { return digest }
        let digest = computePluginDigest(plugin)
        if let stamp { digestCache.keep(key, stamp: stamp, digest: digest) }
        return digest
    }

    /// How many times `plugin`'s digest was taken in full, for the test that it is not
    /// taken again when nothing changed.
    static func pluginDigestsTaken(_ plugin: URL) -> Int {
        digestCache.taken(plugin.standardizedFileURL.path)
    }

    /// What `lstat` says of every entry under the folder, as one number; nil when the
    /// folder cannot be listed.
    static func pluginStamp(_ plugin: URL) -> Int? {
        let fileManager = FileManager.default
        var hasher = Hasher()
        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: plugin.path) {
            hasher.combine(destination)
        }
        let root = plugin.resolvingSymlinksInPath().standardizedFileURL.path
        guard isDirectory(URL(filePath: root)), let enumerator = fileManager.enumerator(atPath: root) else { return nil }
        hasher.combine(statLine(root, following: false))
        for case let relative as String in enumerator {
            if ignoredInDigest.contains((relative as NSString).lastPathComponent) { continue }
            let path = root + "/" + relative
            hasher.combine(relative)
            hasher.combine(statLine(path, following: false))
            // A link to a file is digested by its content, which lives where it points.
            if let destination = try? fileManager.destinationOfSymbolicLink(atPath: path) {
                hasher.combine(destination)
                hasher.combine(statLine(path, following: true))
            }
        }
        return hasher.finalize()
    }

    private static func statLine(_ path: String, following: Bool) -> String {
        var info = stat()
        guard (following ? stat(path, &info) : lstat(path, &info)) == 0 else { return "?" }
        #if canImport(Darwin)
        let modified = info.st_mtimespec, changed = info.st_ctimespec
        #else
        let modified = info.st_mtim, changed = info.st_ctim
        #endif
        return "\(info.st_ino) \(info.st_size) \(modified.tv_sec).\(modified.tv_nsec) \(changed.tv_sec).\(changed.tv_nsec)"
    }

    /// Every file read and hashed: what `pluginDigest` keeps.
    private static func computePluginDigest(_ plugin: URL) -> String? {
        let fileManager = FileManager.default
        var lines: [String] = []
        // The folder itself may be a link (`pluginFolders` takes one to a folder); where
        // it points is part of what was approved.
        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: plugin.path) {
            lines.append("R \(destination)")
        }
        let root = plugin.resolvingSymlinksInPath()
        guard isDirectory(root),
              let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil,
                                                      options: [], errorHandler: { _, _ in true }) else { return nil }
        let base = root.standardizedFileURL.path
        var entries: [(path: String, url: URL)] = []
        for case let url as URL in enumerator {
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(base + "/") else { continue }
            let relative = String(full.dropFirst(base.count + 1))
            if ignoredInDigest.contains(url.lastPathComponent) { continue }
            entries.append((relative, url))
        }
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            let path = entry.url.path
            if let destination = try? fileManager.destinationOfSymbolicLink(atPath: path) {
                var line = "L \(entry.path) -> \(destination)"
                let target = entry.url.resolvingSymlinksInPath()
                if !isDirectory(target), let data = try? Data(contentsOf: target) {
                    line += " " + ContentDigest.sha256(data)
                }
                lines.append(line)
            } else if isDirectory(entry.url) {
                lines.append("D \(entry.path)")
            } else if let data = try? Data(contentsOf: entry.url) {
                lines.append("F \(entry.path) " + ContentDigest.sha256(data))
            } else {
                lines.append("U \(entry.path)")
            }
        }
        return ContentDigest.sha256(Data(lines.joined(separator: "\n").utf8))
    }

    /// What the plugin brings, in the words its row uses. Read off where each runtime
    /// looks: hooks and MCP servers, which run by themselves, first.
    public static func pluginCarries(_ plugin: URL) -> [String] {
        let manifest = pluginManifest(of: plugin)
        let has = { (path: String) in exists(plugin.appending(path: path)) }
        var carries: [String] = []
        if has("hooks") || manifest["hooks"] != nil { carries.append("hooks") }
        if mcpServers(of: plugin, manifest: manifest) != nil
            || (json(at: plugin.appending(path: geminiManifest))?["mcpServers"] as? [String: Any])?.isEmpty == false {
            carries.append("MCP servers")
        }
        for (folder, words) in [("skills", "skills"), ("commands", "commands"), ("agents", "agents")] where has(folder) {
            carries.append(words)
        }
        return carries
    }
}

/// The plugin digests already taken, by folder. Bounded: a daemon sees a few projects'
/// plugins, and past the bound the whole cache starts again.
final class PluginDigestCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (stamp: Int, digest: String?)] = [:]
    private var counts: [String: Int] = [:]
    static let bound = 256

    func digest(_ key: String, stamp: Int) -> String?? {
        lock.withLock {
            guard let entry = entries[key], entry.stamp == stamp else { return nil }
            return .some(entry.digest)
        }
    }

    func keep(_ key: String, stamp: Int, digest: String?) {
        lock.withLock {
            if entries[key] == nil, entries.count >= Self.bound {
                entries.removeAll()
                counts.removeAll()
            }
            entries[key] = (stamp, digest)
            counts[key, default: 0] += 1
        }
    }

    func taken(_ key: String) -> Int {
        lock.withLock { counts[key] ?? 0 }
    }
}

extension DotAgents {
    static let digestCache = PluginDigestCache()
}
