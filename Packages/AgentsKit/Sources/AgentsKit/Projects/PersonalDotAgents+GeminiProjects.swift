import Foundation

/// A project's plugins, handed to Gemini. Gemini reads extensions only from
/// `~/.gemini/extensions` — it has no project folder for them — so before a Gemini agent
/// starts, each plugin in the project's `.agents/plugins` gets an absolute link there,
/// named for its `gemini-extension.json`, and is switched on only inside that project:
///
///     ~/.gemini/extensions/<name> -> <project>/.agents/plugins/<plugin>
///     ~/.gemini/extensions/extension-enablement.json
///         "<name>": { "overrides": ["!/*", "<project>/*"] }
///
/// Read off Gemini CLI 0.61.0's code — an ACP session loads extensions for its own `cwd`,
/// and an override's last matching rule wins — then probed with the app's own Gemini
/// 0.61.0 in a scratch home (2026-09-26): `gemini extensions list` loads the linked folder,
/// on from the project and a folder inside it, off from anywhere else.
///
/// Two extensions with one name stop Gemini loading any extension at all ("Extension with
/// name … already was loaded"), so a name already in the folder — the person's own, a
/// personal plugin's, another project's — is left to whoever has it, and said in the log.
///
/// Links are recorded by absolute path, as Antigravity's skill links are, so the personal
/// sweep of `.gemini/extensions` never mistakes them for its own. A link the person deleted
/// stays deleted; one whose plugin is gone is removed with its override.
extension PersonalDotAgents {
    static let geminiEnablement = "extension-enablement.json"

    static func linkGeminiProjectExtensions(home: URL, cwd: URL, record: inout Record) {
        let fileManager = FileManager.default
        let extensions = home.appending(path: geminiExtensions, directoryHint: .isDirectory)
        if (try? fileManager.destinationOfSymbolicLink(atPath: extensions.path)) != nil { return }
        sweepGeminiProjectLinks(in: extensions, record: &record)
        let project = DotAgents.projectFolder(for: cwd)
        guard DotAgents.isLayable(project) else { return }
        for plugin in DotAgents.pluginFolders(for: cwd) {
            attempt("write \(DotAgents.geminiManifest) for \(plugin.lastPathComponent)") {
                try DotAgents.writeGeminiManifest(for: plugin)
            }
            guard let name = geminiName(of: plugin) else { continue }
            let link = extensions.appending(path: name)
            let target = plugin.path
            if let existing = try? fileManager.destinationOfSymbolicLink(atPath: link.path) {
                if existing == target {
                    record.links[link.path] = target
                    scopeGeminiExtension(name, to: scopes(project: project, cwd: cwd), in: extensions)
                } else {
                    DaemonLog.shared.write("gemini extensions: left \(name) out of \(project.path): the name is taken")
                }
                continue
            }
            if DotAgents.exists(link) || geminiNames(in: extensions)[name] != nil {
                DaemonLog.shared.write("gemini extensions: left \(name) out of \(project.path): the name is taken")
                continue
            }
            if record.links[link.path] == target { continue }  // placed once, removed by the person
            // Scoped before it exists, so no Gemini starting meanwhile sees it everywhere; and
            // not linked at all when the scope could not be written.
            guard scopeGeminiExtension(name, to: scopes(project: project, cwd: cwd), in: extensions) else { continue }
            attempt("link \(geminiExtensions)/\(name)") {
                try fileManager.createDirectory(at: extensions, withIntermediateDirectories: true)
                try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: target)
                record.links[link.path] = target
            }
            if record.links[link.path] != target { unscopeGeminiExtension(name, in: extensions) }
        }
    }

    /// Each recorded project link: gone with its plugin, or given up to an extension of the
    /// same name that arrived since (a personal plugin wins). The person's removal is kept.
    static func sweepGeminiProjectLinks(in extensions: URL, record: inout Record) {
        let fileManager = FileManager.default
        let prefix = extensions.path + "/"
        for (path, target) in record.links where path.hasPrefix(prefix) {
            let link = URL(filePath: path)
            let name = link.lastPathComponent
            let destination = try? fileManager.destinationOfSymbolicLink(atPath: path)
            if !DotAgents.isDirectory(URL(filePath: target)) {
                if destination == target {
                    attempt("remove the dangling link \(geminiExtensions)/\(name)") { try fileManager.removeItem(at: link) }
                }
                if destination == target || destination == nil {
                    record.links.removeValue(forKey: path)
                    unscopeGeminiExtension(name, in: extensions)
                }
                continue
            }
            guard destination == target else { continue }
            let others = (geminiNames(in: extensions)[name] ?? []).filter { $0 != name }
            if !others.isEmpty {
                attempt("give up \(geminiExtensions)/\(name) to \(others.joined(separator: ", "))") {
                    try fileManager.removeItem(at: link)
                }
                record.links.removeValue(forKey: path)
                unscopeGeminiExtension(name, in: extensions)
            }
        }
    }

    /// The name Gemini loads a plugin by: its `gemini-extension.json`'s.
    static func geminiName(of plugin: URL) -> String? {
        guard let name = DotAgents.json(at: plugin.appending(path: DotAgents.geminiManifest))?["name"] as? String,
              !name.isEmpty else { return nil }
        return name
    }

    /// Every extension in the folder by the name Gemini loads it under, to the entries it
    /// is in. A linked install (`gemini extensions link`) is read at its source, as Gemini does.
    static func geminiNames(in extensions: URL) -> [String: [String]] {
        var names: [String: [String]] = [:]
        for entry in (try? FileManager.default.contentsOfDirectory(atPath: extensions.path)) ?? [] {
            let folder = extensions.appending(path: entry, directoryHint: .isDirectory)
            guard !entry.hasPrefix("."), DotAgents.isDirectory(folder.resolvingSymlinksInPath()) else { continue }
            var source = folder
            if let install = DotAgents.json(at: folder.appending(path: ".gemini-extension-install.json")),
               install["type"] as? String == "link", let path = install["source"] as? String {
                source = URL(filePath: path, directoryHint: .isDirectory)
            }
            if let name = geminiName(of: source) { names[name, default: []].append(entry) }
        }
        return names
    }

    /// The folders an agent in the project may be in, as Gemini will see them: the project
    /// resolved, and as the agent's folder spells it when a link is on the way. Both, because
    /// the probe found a rule for `/tmp/…` alone left it off in a folder Gemini saw as
    /// `/private/tmp/…`.
    static func scopes(project: URL, cwd: URL) -> [String] {
        var spelled = cwd.standardizedFileURL.path
        if let range = spelled.range(of: "/\(WorktreeName.folder)/") { spelled = String(spelled[..<range.lowerBound]) }
        return Array(Set([project.path, spelled])).sorted()
    }

    /// Off everywhere, then on under each folder: the last matching rule wins.
    static func geminiOverrides(for folders: [String]) -> [String] {
        ["!/*"] + folders.map { ($0.hasSuffix("/") ? $0 : $0 + "/") + "*" }
    }

    /// False when the rules could not be put in place.
    @discardableResult
    static func scopeGeminiExtension(_ name: String, to folders: [String], in extensions: URL) -> Bool {
        guard var config = geminiEnablementConfig(in: extensions) else { return false }
        let overrides = geminiOverrides(for: folders)
        guard (config[name] as? [String: Any])?["overrides"] as? [String] != overrides else { return true }
        config[name] = ["overrides": overrides]
        return writeGeminiEnablement(config, in: extensions)
    }

    static func unscopeGeminiExtension(_ name: String, in extensions: URL) {
        guard var config = geminiEnablementConfig(in: extensions),
              let overrides = (config[name] as? [String: Any])?["overrides"] as? [String],
              overrides.first == "!/*" else { return }  // the person's own rules for that name
        config.removeValue(forKey: name)
        _ = writeGeminiEnablement(config, in: extensions)
    }

    /// The enablement rules, empty when there is no file; nil when one is there and cannot
    /// be read, which is then left as it is rather than written over.
    private static func geminiEnablementConfig(in extensions: URL) -> [String: Any]? {
        let url = extensions.appending(path: geminiEnablement)
        guard DotAgents.exists(url) else { return [:] }
        guard let config = DotAgents.json(at: url) else {
            DaemonLog.shared.write("gemini extensions: \(geminiExtensions)/\(geminiEnablement) cannot be read, so it is left alone")
            return nil
        }
        return config
    }

    private static func writeGeminiEnablement(_ config: [String: Any], in extensions: URL) -> Bool {
        var wrote = false
        attempt("write \(geminiExtensions)/\(geminiEnablement)") {
            try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
            try DotAgents.encoded(config).write(to: extensions.appending(path: geminiEnablement), options: .atomic)
            wrote = true
        }
        return wrote
    }
}
