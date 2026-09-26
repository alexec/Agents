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
extension DotAgents {
    static let ignoredInDigest: Set<String> = [".DS_Store"]

    /// The digest of `plugin`'s folder, or nil when it cannot be read at all.
    public static func pluginDigest(_ plugin: URL) -> String? {
        attempt("write \(geminiManifest) for \(plugin.lastPathComponent)") { try writeGeminiManifest(for: plugin) }
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
