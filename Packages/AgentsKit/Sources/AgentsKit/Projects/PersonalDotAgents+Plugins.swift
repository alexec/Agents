import AgentsKitCore
import Foundation

/// The person's plugins, in `~/.agents/plugins` (054, research R12): one folder each, in
/// the shape Claude's plugins have, handed to each runtime the least-writing way R9 found.
///
///     Claude, Grok   the folders in the session's `_meta`, after the project's own
///     Grok           and each plugin's MCP servers in `mcpServers`, since Grok starts none
///     Codex          ~/.agents/plugins/marketplace.json, then `codex plugin add` on a change
///     Gemini         ~/.gemini/extensions/<name> -> ../../.agents/plugins/<name>
///     Cursor, Copilot  no way in from the app
extension PersonalDotAgents {
    public static let plugins = "plugins"
    /// The marketplace Codex knows the person's plugins by.
    public static let codexMarketplace = "agents-personal"
    static let geminiExtensions = ".gemini/extensions"

    public static func personalPluginFolders(home: URL) -> [URL] {
        DotAgents.pluginFolders(in: home.appending(path: "\(folder)/\(plugins)", directoryHint: .isDirectory))
    }

    /// What a plugin is, for the Shared tab and the Codex index.
    public struct PluginInfo: Codable, Equatable, Sendable {
        public struct Contents: Codable, Equatable, Sendable {
            public var skills = 0
            public var commands = 0
            public var agents = 0
            public var hooks = 0
            public var mcpServers = 0
        }

        public var name: String
        public var version: String?
        public var description: String?
        public var path: String
        public var contents: Contents
    }

    public static func pluginInfo(_ plugin: URL) -> PluginInfo {
        let manifest = DotAgents.pluginManifest(of: plugin)
        var contents = PluginInfo.Contents()
        contents.skills = entries(plugin, "skills").filter { DotAgents.isDirectory(plugin.appending(path: "skills/\($0)")) }.count
        contents.commands = entries(plugin, "commands").filter { $0.hasSuffix(".md") }.count
        contents.agents = entries(plugin, "agents").filter { $0.hasSuffix(".md") }.count
        if let hooks = DotAgents.json(at: plugin.appending(path: "hooks/hooks.json")) {
            contents.hooks = (hooks["hooks"] as? [String: Any] ?? hooks).count
        }
        contents.mcpServers = pluginServers(plugin).count
        return PluginInfo(name: manifest["name"] as? String ?? plugin.lastPathComponent,
                          version: manifest["version"] as? String,
                          description: manifest["description"] as? String,
                          path: plugin.path, contents: contents)
    }

    private static func entries(_ plugin: URL, _ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: plugin.appending(path: folder).path)) ?? [])
            .filter { !$0.hasPrefix(".") }
    }

    /// A plugin's MCP servers, from its `.mcp.json` (under `mcpServers`, or the servers
    /// themselves) or its manifest, with `${CLAUDE_PLUGIN_ROOT}` put in as the folder, the
    /// way Claude would start them. One that cannot be read is left out, by name.
    public static func pluginServers(_ plugin: URL) -> [MCPServer] {
        let fileURL = plugin.appending(path: ".mcp.json")
        let data = try? Data(contentsOf: fileURL)
        let file = DotAgents.json(at: fileURL)
        let listed: [String: Any]
        let order: [String]?
        if let servers = file?["mcpServers"] as? [String: Any] {
            listed = servers
            order = data.flatMap { orderedKeys(of: "mcpServers", in: $0) }
        } else if let file, !file.isEmpty {
            listed = file
            order = nil
        } else {
            listed = DotAgents.pluginManifest(of: plugin)["mcpServers"] as? [String: Any] ?? [:]
            order = nil
        }
        return (order ?? listed.keys.sorted()).compactMap { name in
            guard let value = listed[name] else { return nil }
            switch server(named: name, value) {
            case .success(let server): return server.rootedAt(plugin)
            case .failure(let problem):
                DaemonLog.shared.write("personal plugins: \(plugin.lastPathComponent): \(problem.message)")
                return nil
            }
        }
    }

    /// Every server in every personal plugin, for a runtime that starts none of them itself.
    public static func personalPluginServers(home: URL) -> [MCPServer] {
        personalPluginFolders(home: home).flatMap(pluginServers)
    }

    /// Each file's path in the plugin, size and modification date, hashed: what changes
    /// when anything in the plugin is added, removed or edited (R12).
    public static func fingerprint(_ plugin: URL) -> String {
        let root = plugin.resolvingSymlinksInPath()
        var lines: [String] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) {
            for case let url as URL in walker {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                let relative = String(url.resolvingSymlinksInPath().path.dropFirst(root.path.count))
                let modified = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
                lines.append("\(relative)\t\(values.fileSize ?? 0)\t\(modified)")
            }
        }
        // FNV-1a, 64 bits: a change detector, not a secret.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in lines.sorted().joined(separator: "\n").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    // MARK: - Gemini (R12)

    /// One link per personal plugin in `~/.gemini/extensions`, placed and recorded like a
    /// skill link, and a `gemini-extension.json` written into the plugin when it has none.
    static func linkGeminiExtensions(home: URL, record: inout Record) {
        let shared = "\(folder)/\(plugins)"
        sweep(home: home, folder: geminiExtensions, sharedFolder: shared, present: personalPluginNames(home: home),
              record: &record)
        let target = home.appending(path: geminiExtensions, directoryHint: .isDirectory)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil { return }
        for plugin in personalPluginFolders(home: home) {
            let name = plugin.lastPathComponent
            attempt("write \(DotAgents.geminiManifest) for \(name)") { try DotAgents.writeGeminiManifest(for: plugin) }
            placeLink(home: home, at: "\(geminiExtensions)/\(name)", to: "\(shared)/\(name)", record: &record)
        }
    }

    static func personalPluginNames(home: URL) -> Set<String> {
        Set(personalPluginFolders(home: home).map(\.lastPathComponent))
    }

    // MARK: - Codex (R12)

    /// `~/.agents/plugins/marketplace.json`, the app's index of the person's plugins. Codex
    /// finds it by itself and reads sources against the home folder, hence `./.agents/…`.
    /// One the person wrote is never touched. False when it is not the app's to write.
    @discardableResult
    static func writeCodexIndex(home: URL, plugins found: [URL]) -> Bool {
        let url = home.appending(path: "\(folder)/\(plugins)/\(DotAgents.pluginIndex)")
        if DotAgents.exists(url) {
            guard let index = DotAgents.json(at: url),
                  (index["metadata"] as? [String: Any])?["description"] as? String == DotAgents.indexMarker else { return false }
        } else if found.isEmpty {
            return true
        }
        let entries: [[String: Any]] = found.map { plugin in
            let manifest = DotAgents.pluginManifest(of: plugin)
            var entry: [String: Any] = ["name": manifest["name"] as? String ?? plugin.lastPathComponent,
                                        "source": "./\(folder)/\(plugins)/\(plugin.lastPathComponent)"]
            for key in ["description", "version"] { entry[key] = manifest[key] as? String }
            return entry
        }
        let index: [String: Any] = ["name": codexMarketplace, "owner": ["name": "Agents"],
                                    "metadata": ["description": DotAgents.indexMarker], "plugins": entries]
        var wrote = true
        attempt("write \(folder)/\(plugins)/\(DotAgents.pluginIndex)") {
            let data = try DotAgents.encoded(index)
            if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
        }
        if !DotAgents.exists(url) { wrote = false }
        return wrote
    }

    /// What Codex needs doing: plugins to add (new or changed, with the fingerprint to
    /// record once the add works) and plugins to remove (recorded, and gone).
    struct CodexChanges: Equatable {
        var add: [(name: String, fingerprint: String)]
        var remove: [String]

        static func == (a: CodexChanges, b: CodexChanges) -> Bool {
            a.add.map(\.name) == b.add.map(\.name) && a.add.map(\.fingerprint) == b.add.map(\.fingerprint)
                && a.remove == b.remove
        }
    }

    static func codexChanges(home: URL, record: Record) -> CodexChanges {
        var changes = CodexChanges(add: [], remove: [])
        var present = Set<String>()
        for plugin in personalPluginFolders(home: home) {
            let name = DotAgents.pluginManifest(of: plugin)["name"] as? String ?? plugin.lastPathComponent
            present.insert(name)
            let print = fingerprint(plugin)
            if record.codexPlugins[name] != print { changes.add.append((name, print)) }
        }
        changes.remove = record.codexPlugins.keys.filter { !present.contains($0) }.sorted()
        return changes
    }
}

extension MCPServer {
    /// A plugin's server as its runtime would start it: `${CLAUDE_PLUGIN_ROOT}` is the folder.
    func rootedAt(_ plugin: URL) -> MCPServer {
        let root = plugin.path
        func fill(_ text: String) -> String { text.replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: root) }
        switch transport {
        case .stdio(let command, let args, let env):
            return MCPServer(name: name, transport: .stdio(command: fill(command), args: args.map(fill),
                                                           env: env.mapValues(fill)))
        case .http, .sse:
            return self
        }
    }
}
