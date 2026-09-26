import Foundation

/// What the project's plugins need for the runtimes that will not take a folder.
///
///     .agents/plugins/marketplace.json            the index, rebuilt from the folders
///     .claude-plugin/marketplace.json -> ../.agents/plugins/marketplace.json
///     .agents/plugins/<plugin>/gemini-extension.json
///
/// Codex and Copilot load plugins only from a marketplace, and a marketplace is a folder
/// with an index in it. The project is that folder, added once with `codex plugin
/// marketplace add <project>` or `copilot plugin marketplace add <project>` (Claude's
/// `/plugin marketplace add` takes it too). One index serves all three, measured with
/// each CLI against a scratch home: Codex looks for `.agents/plugins/marketplace.json`
/// first, which is its own convention, and Claude and Copilot for
/// `.claude-plugin/marketplace.json`, which is the link. Sources are plain `./` paths from
/// the project, which Codex accepts beside its own `{"source": "local"}` objects. Copilot
/// loads a local marketplace's plugins in place, so an edit is live next session.
///
/// Cursor is not reached: its marketplaces are git URLs held by the account, and its
/// ACP mode ignores `--plugin-dir`, so only its own `~/.cursor/plugins/local` would do.
///
/// Gemini reads extensions only from `~/.gemini/extensions`, where `gemini extensions
/// link <plugin>` puts one; what it needs from the plugin is `gemini-extension.json`.
///
/// The index is the app's, and says so in its description: it is rebuilt whenever the
/// folders change, and one the person wrote themselves is never touched. A Gemini
/// manifest is written once, when a plugin has none, and is the person's after that.
extension DotAgents {
    public static let pluginIndex = "marketplace.json"
    public static let geminiManifest = "gemini-extension.json"

    /// Made with the index, not with the layout, so there is no link to nothing.
    static let indexLink = Link(path: ".claude-plugin/marketplace.json",
                                destination: "../\(folder)/\(plugins)/\(pluginIndex)", since: 2)

    /// How an index the app wrote is told from one the person did.
    static let indexMarker = "Written by the Agents app from the folders in .agents/plugins, and rebuilt when they change. Edit the plugins, not this file."

    /// Bring the index and the Gemini manifests up to date with `.agents/plugins`.
    /// Cheap when nothing changed: nothing is written unless its contents would differ.
    ///
    /// The index lists only `approved`, when given: a plugin waiting for the person's OK
    /// is not offered to the runtimes that load it from there (security review, S2).
    public static func refreshPlugins(for cwd: URL, approved: [URL]? = nil) {
        let project = projectFolder(for: cwd)
        let folderURL = project.appending(path: "\(folder)/\(plugins)", directoryHint: .isDirectory)
        guard isLayable(project), isDirectory(folderURL) else { return }
        var found = pluginFolders(in: folderURL)
        if let approved {
            let keys = Set(approved.map(\.standardizedFileURL.path))
            found = found.filter { keys.contains($0.standardizedFileURL.path) }
        }
        for plugin in found {
            attempt("write \(geminiManifest) for \(plugin.lastPathComponent)") { try writeGeminiManifest(for: plugin) }
        }
        attempt("write \(folder)/\(plugins)/\(pluginIndex)") {
            try writeIndex(in: project, plugins: found)
        }
    }

    static func writeIndex(in project: URL, plugins found: [URL]) throws {
        let url = project.appending(path: "\(folder)/\(plugins)/\(pluginIndex)")
        let existed = exists(url)
        if existed {
            guard let index = json(at: url),
                  (index["metadata"] as? [String: Any])?["description"] as? String == indexMarker else { return }
        } else if found.isEmpty {
            return
        }
        let data = try encoded(indexContents(for: project, plugins: found))
        if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
        // Once, with the index: a link the person deleted later is not put back.
        if !existed { try place(indexLink, in: project) }
    }

    static func indexContents(for project: URL, plugins found: [URL]) -> [String: Any] {
        let entries: [[String: Any]] = found.map { plugin in
            let manifest = pluginManifest(of: plugin)
            var entry: [String: Any] = [
                "name": manifest["name"] as? String ?? plugin.lastPathComponent,
                "source": "./\(folder)/\(plugins)/\(plugin.lastPathComponent)",
            ]
            for key in ["description", "version"] { entry[key] = manifest[key] as? String }
            return entry
        }
        let name = kebab(project.lastPathComponent)
        return [
            "name": name.isEmpty ? "project" : name,
            "owner": ["name": project.lastPathComponent],
            "metadata": ["description": indexMarker],
            "plugins": entries,
        ]
    }

    /// Written only where the plugin has none, from what its own manifest says.
    static func writeGeminiManifest(for plugin: URL) throws {
        let url = plugin.appending(path: geminiManifest)
        guard !exists(url) else { return }
        let manifest = pluginManifest(of: plugin)
        var name = kebab(manifest["name"] as? String ?? plugin.lastPathComponent)
        if name.isEmpty { name = kebab(plugin.lastPathComponent) }
        var extensionManifest: [String: Any] = [
            "name": name,
            "version": manifest["version"] as? String ?? "0.1.0",
            "description": manifest["description"] as? String ?? "",
        ]
        if let servers = mcpServers(of: plugin, manifest: manifest) {
            extensionManifest["mcpServers"] = servers
        }
        try encoded(extensionManifest).write(to: url, options: .atomic)
    }

    /// The plugin's MCP servers, from its `.mcp.json` or its manifest, with Claude's
    /// name for the plugin's folder put in Gemini's.
    static func mcpServers(of plugin: URL, manifest: [String: Any]) -> Any? {
        // `.mcp.json` holds its servers under `mcpServers`, or is the servers itself.
        let file = json(at: plugin.appending(path: ".mcp.json"))
        let servers = file?["mcpServers"] as? [String: Any] ?? file ?? manifest["mcpServers"] as? [String: Any]
        guard let servers, !servers.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: servers),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let translated = text.replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: "${extensionPath}")
        return try? JSONSerialization.jsonObject(with: Data(translated.utf8))
    }

    /// The first manifest the plugin has, in the order the runtimes that read them agree
    /// on: the one every runtime but Antigravity reads, then the rest.
    static func pluginManifest(of plugin: URL) -> [String: Any] {
        let places = [".claude-plugin/plugin.json", "plugin.json", ".codex-plugin/plugin.json",
                      ".cursor-plugin/plugin.json", ".grok-plugin/plugin.json", ".github/plugin/plugin.json"]
        for place in places {
            if let manifest = json(at: plugin.appending(path: place)) { return manifest }
        }
        return [:]
    }

    /// Lowercase letters, digits, dots and single dashes: what both a marketplace name
    /// and a Gemini extension name allow.
    static func kebab(_ name: String) -> String {
        var out = ""
        for character in name.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber || character == "." {
                out.append(character)
            } else if !out.hasSuffix("-") {
                out.append("-")
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    }

    static func json(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Sorted and pretty, so the same plugins are the same bytes and nothing is written.
    static func encoded(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }
}
